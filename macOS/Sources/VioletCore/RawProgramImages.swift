import Foundation

/// Imports complete partition images from rawprogram XML for named-partition
/// flashing. Physical GPT writes and segmented physical entries are excluded.
public struct RawProgramImages: Sendable {
    public struct Entry: Sendable {
        public let label: String
        public let relativeImage: String
        public let imageURL: URL
    }
    public let root: URL
    public let entries: [Entry]
    public let skipped: [String]
    private let snapshots: [FileSnapshot]

    public static func open(_ files: [URL], control: WorkControl = WorkControl()) throws -> RawProgramImages {
        let files = Array(Set(files.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard let first = files.first, files.count <= 256 else { throw InputError.invalid("请选择 1–256 个 rawprogram XML。") }
        let directory = first.deletingLastPathComponent(), actualRoot = directory.resolvingSymlinksInPath()
        guard files.allSatisfy({ $0.deletingLastPathComponent() == directory }) else { throw InputError.invalid("同一批 rawprogram XML 需放在同一个包目录。") }
        var entries: [Entry] = [], skipped: [String] = [], blocked: Set<String> = [], snapshots: [FileSnapshot] = [], total: UInt64 = 0, count = 0
        for file in files {
            try control.check()
            let snapshot = try FileSnapshot(file); snapshots.append(snapshot)
            total = try checkedAdd(total, snapshot.size)
            guard snapshot.size <= 16 * 1024 * 1024, total <= 32 * 1024 * 1024 else { throw InputError.invalid("rawprogram XML 总量超过解析限制。") }
            let data = try Data(contentsOf: file)
            let text: String?
            if data.starts(with: [0xff,0xfe]) || data.starts(with: [0xfe,0xff]) { text = String(data: data, encoding: .utf16) }
            else { text = String(data: data, encoding: .utf8) }
            guard let text else { throw InputError.invalid("XML 需要 UTF-8 或带 BOM 的 UTF-16：\(file.lastPathComponent)") }
            let root = try FirmwareXML.parse(text)
            guard root.name.lowercased() == "data" else { throw InputError.invalid("不是 rawprogram data 文档：\(file.lastPathComponent)") }
            for node in root.descendants where node.name.lowercased() == "program" {
                try control.check(); count += 1
                guard count <= 16384 else { throw InputError.invalid("rawprogram 条目超过 16384。") }
                let label = (node.attributes["label"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rawName = (node.attributes["filename"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let key = label.lowercased(), basename = rawName.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
                if ["primarygpt","backupgpt","gpt"].contains(key) || basename.hasPrefix("gpt_main") || basename.hasPrefix("gpt_backup") {
                    skipped.append("\(file.lastPathComponent)：跳过 GPT 物理条目 \(label)"); continue
                }
                guard !label.isEmpty, !rawName.isEmpty else { skipped.append("\(file.lastPathComponent)：跳过无标签或无镜像条目"); continue }
                do {
                    _ = try Input.partition(label)
                    let offset = (node.attributes["file_sector_offset"] ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard UInt64(offset) == 0 else { throw InputError.invalid("文件偏移非零或无效，不能作为完整分区镜像") }
                    guard !blocked.contains(key), !entries.contains(where: { $0.label.lowercased() == key }) else { throw InputError.invalid("同名分区含多个条目，不能作为完整分区镜像") }
                    let relative = try ArchivePaths.normalize(rawName), source = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
                    guard source.path.hasPrefix(actualRoot.path + "/") else { throw InputError.invalid("镜像指向包目录之外") }
                    let image = try FileSnapshot(source)
                    guard image.size > 0 else { throw InputError.invalid("镜像为空") }
                    entries.append(Entry(label: label, relativeImage: relative, imageURL: source))
                } catch {
                    blocked.insert(key); entries.removeAll { $0.label.lowercased() == key }
                    skipped.append("\(file.lastPathComponent) / \(label)：\(error.localizedDescription)")
                }
            }
            try snapshot.validate()
        }
        guard !entries.isEmpty else { throw InputError.invalid("没有可用于命名分区刷写的完整镜像。\n" + skipped.prefix(30).joined(separator: "\n")) }
        return RawProgramImages(root: directory, entries: entries, skipped: skipped, snapshots: snapshots)
    }

    public func validate() throws { for snapshot in snapshots { try snapshot.validate() } }
    public func flashPlan() throws -> FlashPlan {
        try validate()
        return try FlashPlan.create(root: root, steps: entries.map { FlashStep(.flash, target: $0.label, image: $0.relativeImage) })
    }
}
