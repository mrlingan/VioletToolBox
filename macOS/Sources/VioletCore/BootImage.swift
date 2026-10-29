import Foundation

public struct BootComponent: Identifiable, Codable, Sendable {
    public let name: String
    public let offset: UInt64
    public let size: UInt64
    public var id: String { name }
}

public struct BootImage: Sendable {
    public let sourceURL: URL
    public let version: UInt64
    public let pageSize: UInt64
    public let commandLine: String
    public let components: [BootComponent]
    public var kind: String { components.contains(where: { $0.name == "kernel" }) ? "boot" : "init_boot / ramdisk-only boot" }
    private let snapshot: FileSnapshot

    public static func open(_ url: URL) throws -> BootImage {
        let snapshot = try FileSnapshot(url), file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.readExactly(offset: 0, count: Int(min(snapshot.size, 4096)), fileSize: snapshot.size)
        guard header.prefix(8) == Data("ANDROID!".utf8) else { throw InputError.invalid("不是 Android boot / init_boot 镜像；vendor_boot 与厂商封装暂不支持。") }
        let version = try header.integer(at: 40, bytes: 4)
        guard version <= 4 else { throw InputError.invalid("不支持 Boot header v\(version)。") }
        let page = version >= 3 ? 4096 : try header.integer(at: 36, bytes: 4)
        let minimum = [1632, 1648, 1660, 1580, 1584][Int(version)]
        guard page >= UInt64(minimum), page <= 65536, page.nonzeroBitCount == 1, header.count >= minimum else { throw InputError.invalid("Boot 页大小或文件头长度无效。") }
        if version > 0 {
            let length = try header.integer(at: version >= 3 ? 20 : 1644, bytes: 4)
            guard length == UInt64(minimum) else { throw InputError.invalid("Boot header_size 与版本不匹配。") }
        }
        var limit = snapshot.size
        if snapshot.size >= 64 {
            let footer = try file.readExactly(offset: snapshot.size - 64, count: 64, fileSize: snapshot.size)
            if footer.prefix(4) == Data("AVBf".utf8) {
                let original = try footer.integer(at: 12, bytes: 8, bigEndian: true)
                let meta = try footer.integer(at: 20, bytes: 8, bigEndian: true)
                let metaSize = try footer.integer(at: 28, bytes: 8, bigEndian: true)
                guard try footer.integer(at: 4, bytes: 4, bigEndian: true) == 1,
                      original >= page, original <= meta, try checkedAdd(meta, metaSize) <= snapshot.size - 64 else { throw InputError.invalid("Boot AVB footer 范围无效。") }
                limit = original
            }
        }
        func aligned(_ n: UInt64) throws -> UInt64 { try checkedAdd(n, page - 1) / page * page }
        var parts: [BootComponent] = [], cursor = page
        func add(_ name: String, _ size: UInt64, offset: UInt64? = nil) throws {
            if let offset { guard offset >= cursor, offset % page == 0 else { throw InputError.invalid("Boot 组件偏移重叠或未对齐。") }; cursor = offset }
            guard cursor <= limit, size <= limit - cursor else { throw InputError.invalid("Boot 组件 \(name) 超出镜像范围。") }
            if size > 0 { parts.append(BootComponent(name: name, offset: cursor, size: size)) }
            cursor = try checkedAdd(cursor, aligned(size))
        }
        try add("kernel", header.integer(at: 8, bytes: 4))
        try add("ramdisk", header.integer(at: version >= 3 ? 12 : 16, bytes: 4))
        if version <= 2 {
            try add("second", header.integer(at: 24, bytes: 4))
            if version >= 1 {
                let size = try header.integer(at: 1632, bytes: 4)
                if size > 0 { try add("recovery_dtbo", size, offset: header.integer(at: 1636, bytes: 8)) }
            }
            if version == 2 { try add("dtb", header.integer(at: 1648, bytes: 4)) }
        } else if version == 4 { try add("boot_signature", header.integer(at: 1580, bytes: 4)) }
        guard !parts.isEmpty else { throw InputError.invalid("Boot 镜像没有可导出的组件。") }
        func string(_ range: Range<Int>) -> String {
            String(decoding: header[range].prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let cmdline = version >= 3 ? string(44..<1580) : [string(64..<576), string(608..<1632)].filter { !$0.isEmpty }.joined(separator: " ")
        try snapshot.validate()
        return BootImage(sourceURL: url, version: version, pageSize: page, commandLine: cmdline, components: parts, snapshot: snapshot)
    }

    public func export(to folder: URL, control: WorkControl = WorkControl(), progress: @Sendable (WorkProgress) -> Void = { _ in }) throws -> [URL] {
        try control.check(); try snapshot.validate()
        let file = try FileHandle(forReadingFrom: sourceURL); defer { try? file.close() }
        var outputs: [URL] = []
        for component in components {
            let output = try AtomicOutput(folder.appendingPathComponent(component.name + ".bin"))
            var done: UInt64 = 0
            while done < component.size {
                try control.check()
                let count = Int(min(1024 * 1024, component.size - done))
                try output.handle.write(contentsOf: file.readExactly(offset: component.offset + done, count: count, fileSize: snapshot.size))
                done += UInt64(count); progress(WorkProgress(component.name, done: done, total: component.size))
            }
            try control.check(); try snapshot.validate(); outputs.append(try output.commit())
        }
        let metadata = try AtomicOutput(folder.appendingPathComponent("components.json"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try metadata.handle.write(contentsOf: encoder.encode(components)); outputs.append(try metadata.commit())
        return outputs
    }
}
