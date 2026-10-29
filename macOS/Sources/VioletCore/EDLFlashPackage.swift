import Foundation

public struct EDLFlashPackage: Sendable {
    public struct Step: Identifiable, Sendable {
        public enum Kind: String, Sendable { case program, erase, patch }
        public let id: Int
        public let kind: Kind
        public let label: String
        public let lun: UInt64
        public let sectorSize: UInt64
        public let start: String
        public let sectors: String
        public let source: URL?
        public let fileOffset: UInt64
        public let sparse: Bool
        public let byteOffset: UInt64
        public let patchSize: UInt64
        public let value: String
        public let origin: String
        public var isGPT: Bool {
            ["primarygpt","backupgpt","gpt"].contains(label.lowercased()) || source?.lastPathComponent.lowercased().hasPrefix("gpt_main") == true || source?.lastPathComponent.lowercased().hasPrefix("gpt_backup") == true
        }
        public var displayLabel: String { label.isEmpty ? source?.deletingPathExtension().lastPathComponent ?? kind.rawValue : label }
    }
    public let root: URL
    public let steps: [Step]
    public let skipped: [String]
    private let documents: [FileSnapshot]
    public static func open(_ files: [URL], includeDirectoryPatches: Bool = true, control: WorkControl = WorkControl()) throws -> EDLFlashPackage {
        guard let root = files.first?.deletingLastPathComponent().standardizedFileURL, files.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == root }) else { throw InputError.invalid("请选择同一目录内的 rawprogram / patch XML。") }
        var files = Set(files.map(\.standardizedFileURL))
        if includeDirectoryPatches {
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.lowercased().hasPrefix("patch") && file.pathExtension.lowercased() == "xml" { files.insert(file) }
        }
        guard !files.isEmpty, files.count <= 256 else { throw InputError.invalid("XML 文件数量应为 1–256。") }
        var steps: [Step] = [], skipped: [String] = [], snapshots: [FileSnapshot] = [], total: UInt64 = 0
        let sorted = files.sorted { lhs, rhs in
            let a = lhs.lastPathComponent.lowercased().hasPrefix("patch"), b = rhs.lastPathComponent.lowercased().hasPrefix("patch")
            return a == b ? lhs.lastPathComponent < rhs.lastPathComponent : !a
        }
        for file in sorted {
            try control.check()
            let snapshot = try FileSnapshot(file); snapshots.append(snapshot); total = try checkedAdd(total, snapshot.size)
            guard snapshot.size <= 16 * 1024 * 1024, total <= 32 * 1024 * 1024, let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw InputError.invalid("XML 超出大小限制或不是 UTF-8。") }
            let document = try FirmwareXML.parse(text)
            guard ["data","patches"].contains(document.name.lowercased()) else { throw InputError.invalid("XML 根节点需为 data / patches。") }
            for node in document.children {
                try control.check()
                let kind = node.name.lowercased()
                guard let operation = Step.Kind(rawValue: kind) else { throw InputError.invalid("XML 含未支持的设备命令 \(node.name)，未忽略。") }
                let filename = (node.attribute("filename") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if operation == .patch, !filename.isEmpty && filename.uppercased() != "DISK" { skipped.append("\(file.lastPathComponent)：跳过文件侧 Patch \(filename)，设备端 DISK Patch 单独执行"); continue }
                if operation == .program && filename.isEmpty { skipped.append("\(file.lastPathComponent)：跳过空 filename 占位条目"); continue }
                if operation == .patch && (node.attribute("value") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skipped.append("\(file.lastPathComponent)：跳过空值 Patch 占位条目"); continue }
                guard let lun = Self.literal(node.attribute("physical_partition_number") ?? "0"), lun <= 255,
                      let sector = Self.literal(node.attribute("SECTOR_SIZE_IN_BYTES") ?? ""), [512,1024,2048,4096,8192,16384,32768,65536].contains(sector) else { throw InputError.invalid("XML 的 LUN / SECTOR_SIZE_IN_BYTES 无效。") }
                let label = node.attribute("label") ?? "", origin = file.lastPathComponent
                guard label.utf8.count <= 1024, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InputError.invalid("XML 标签无效。") }
                var source: URL?
                if operation == .program {
                    let path = try ArchivePaths.normalize(filename.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    let file = root.appendingPathComponent(path).resolvingSymlinksInPath()
                    guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw InputError.invalid("XML 镜像位于包目录之外。") }
                    _ = try FileSnapshot(file); source = file
                }
                let sparseText = (node.attribute("sparse") ?? "false").lowercased()
                guard ["true","false","1","0"].contains(sparseText), let fileOffset = Self.literal(node.attribute("file_sector_offset") ?? "0"),
                      let offset = Self.literal(node.attribute("byte_offset") ?? "0"), let width = Self.literal(node.attribute("size_in_bytes") ?? "0") else { throw InputError.invalid("Sparse / 偏移 / Patch 字段无效。") }
                if operation == .patch, ![1,2,4,8].contains(width) || offset > UInt64(UInt32.max) { throw InputError.invalid("Patch 大小或偏移无效。") }
                steps.append(Step(id: steps.count, kind: operation, label: label, lun: lun, sectorSize: sector, start: node.attribute("start_sector") ?? "0", sectors: node.attribute("num_partition_sectors") ?? "0", source: source, fileOffset: fileOffset, sparse: ["true","1"].contains(sparseText), byteOffset: offset, patchSize: width, value: node.attribute("value") ?? "", origin: origin))
                guard steps.count <= 16384 else { throw InputError.invalid("XML 命令数量超限。") }
            }
            try snapshot.validate()
        }
        guard !steps.isEmpty else { throw InputError.invalid("XML 未包含可执行命令。") }
        return EDLFlashPackage(root: root, steps: steps, skipped: skipped, documents: snapshots)
    }
    public func validate() throws { for file in documents { try file.validate() } }
    public func prepare(geometries: [EDLGeometry], selected: Set<Int>, control: WorkControl = WorkControl()) throws -> [PreparedEDLXMLStep] {
        try validate()
        var result: [PreparedEDLXMLStep] = []
        for step in steps where selected.contains(step.id) {
            try control.check()
            guard let geometry = geometries.first(where: { $0.lun == step.lun }), geometry.sectorSize == step.sectorSize else { throw InputError.invalid("\(step.origin)：LUN \(step.lun) 的扇区大小与设备不符。") }
            try geometry.validate()
            let start = try EDLExpression.value(step.start, geometry: geometry)
            if step.kind == .patch {
                let address = try checkedAdd(checkedMultiply(start, geometry.sectorSize), step.byteOffset)
                guard address < geometry.byteCount, step.patchSize <= geometry.byteCount - address else { throw InputError.invalid("Patch 地址越界。") }
                let value = try EDLExpression.patchValue(step.value, bytes: step.patchSize, geometry: geometry)
                result.append(PreparedEDLXMLStep(step: step, geometry: geometry, start: start, sectors: 0, patchValue: value, snapshot: nil, sourceOffset: 0, sourceLength: 0)); continue
            }
            let declared = try EDLExpression.value(step.sectors, geometry: geometry)
            var count = declared, snapshot: FileSnapshot?, sourceOffset: UInt64 = 0, length: UInt64 = 0
            if let source = step.source {
                let file = try FileSnapshot(source); snapshot = file
                if step.sparse {
                    guard step.fileOffset == 0 else { throw InputError.invalid("Sparse 源不能指定非零文件扇区偏移。") }
                    let sparse = try SparseImage.inspect(source, control: control); try sparse.validateContents(control: control)
                    guard sparse.blockSize % geometry.sectorSize == 0, sparse.expandedSize % geometry.sectorSize == 0 else { throw InputError.invalid("Sparse 块未按设备扇区对齐。") }
                    count = sparse.expandedSize / geometry.sectorSize; length = file.size
                    guard declared == 0 || count <= declared else { throw InputError.invalid("Sparse 展开后超过 XML 声明范围。") }
                } else {
                    guard try !SparseImage.isSparse(source) else { throw InputError.invalid("XML 将 Sparse 文件声明为 Raw，请修正 sparse 属性。") }
                    sourceOffset = try checkedMultiply(step.fileOffset, geometry.sectorSize)
                    guard sourceOffset < file.size else { throw InputError.invalid("镜像文件扇区偏移超出文件。") }
                    length = file.size - sourceOffset
                    if declared > 0 { length = min(length, try checkedMultiply(declared, geometry.sectorSize)) }
                    count = try checkedAdd(length, geometry.sectorSize - 1) / geometry.sectorSize
                }
                try file.validate()
            }
            _ = try geometry.arguments(start: start, sectors: count)
            guard count <= UInt64(UInt32.max) else { throw InputError.invalid("单 XML 命令扇区数超过当前 QDL 计数宽度，请拆分命令。") }
            result.append(PreparedEDLXMLStep(step: step, geometry: geometry, start: start, sectors: count, patchValue: "", snapshot: snapshot, sourceOffset: sourceOffset, sourceLength: length))
        }
        guard !result.isEmpty else { throw InputError.invalid("未选择 XML 命令。") }
        return result.filter { $0.step.kind != .patch } + result.filter { $0.step.kind == .patch }
    }
    private static func literal(_ value: String) -> UInt64? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }
    public func stage(_ prepared: [PreparedEDLXMLStep], in directory: URL, bootable: UInt64?, allowSecurityPartition: Bool,
                      control: WorkControl, progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        try validate()
        let programs = XMLElement(name: "data"), patches = XMLElement(name: "patches")
        var files: [Int: URL] = [:]
        for item in prepared { if let file = try item.stageSource(in: directory, control: control, progress: progress) { files[item.step.id] = file } }
        for item in prepared {
            try control.check()
            let step = item.step, node = XMLElement(name: step.kind.rawValue)
            var attrs = ["SECTOR_SIZE_IN_BYTES":String(item.geometry.sectorSize),"physical_partition_number":String(step.lun),"start_sector":String(item.start)]
            if step.kind == .patch {
                attrs.merge(["filename":"DISK","byte_offset":String(step.byteOffset),"size_in_bytes":String(step.patchSize),"value":item.patchValue,"what":step.origin]) { _, new in new }
            } else {
                attrs["num_partition_sectors"] = String(item.sectors); attrs["label"] = step.displayLabel
                if step.kind == .program {
                    guard let file = files[step.id] else { throw InputError.invalid("缺少 XML 镜像稳定副本。") }
                    attrs.merge(["filename":file.path,"file_sector_offset":"0","sparse":step.sparse ? "true" : "false"]) { _, new in new }
                }
            }
            for key in attrs.keys.sorted() { node.addAttribute(XMLNode.attribute(withName: key, stringValue: attrs[key]!) as! XMLNode) }
            (step.kind == .patch ? patches : programs).addChild(node)
        }
        func write(_ root: XMLElement, name: String) throws -> URL {
            let doc = XMLDocument(rootElement: root); doc.version = "1.0"; doc.characterEncoding = "UTF-8"
            let output = try AtomicOutput(directory.appendingPathComponent(name)); try output.handle.write(contentsOf: doc.xmlData(options: .nodePrettyPrint)); return try output.commit()
        }
        let root = XMLElement(name: "violet_flash_transaction")
        if let bootable { root.addAttribute(XMLNode.attribute(withName: "bootable", stringValue: String(bootable)) as! XMLNode) }
        root.addAttribute(XMLNode.attribute(withName: "allow_security", stringValue: allowSecurityPartition ? "1" : "0") as! XMLNode)
        var luns: Set<UInt64> = []
        for item in prepared where luns.insert(item.geometry.lun).inserted {
            let node = XMLElement(name: "lun")
            for (key, value) in [("id",item.geometry.lun),("sector",item.geometry.sectorSize),("total",item.geometry.totalSectors)] { node.addAttribute(XMLNode.attribute(withName: key, stringValue: String(value)) as! XMLNode) }; root.addChild(node)
        }
        for (type, node, name) in [("program",programs,"canonical-program.xml"),("patch",patches,"canonical-patch.xml")] where node.children?.isEmpty == false {
            let file = try write(node, name: name), entry = XMLElement(name: "file")
            entry.addAttribute(XMLNode.attribute(withName: "type", stringValue: type) as! XMLNode)
            entry.addAttribute(XMLNode.attribute(withName: "path", stringValue: file.lastPathComponent) as! XMLNode); root.addChild(entry)
        }
        try control.check(); try validate(); return try write(root, name: "flash-transaction.xml")
    }
}

public struct PreparedEDLXMLStep: Sendable {
    public let step: EDLFlashPackage.Step
    public let geometry: EDLGeometry
    public let start: UInt64
    public let sectors: UInt64
    public let patchValue: String
    private let snapshot: FileSnapshot?
    private let sourceOffset: UInt64
    private let sourceLength: UInt64
    public var stagedBytes: UInt64 { sourceLength }
    fileprivate init(step: EDLFlashPackage.Step, geometry: EDLGeometry, start: UInt64, sectors: UInt64, patchValue: String, snapshot: FileSnapshot?, sourceOffset: UInt64, sourceLength: UInt64) {
        self.step = step; self.geometry = geometry; self.start = start; self.sectors = sectors; self.patchValue = patchValue; self.snapshot = snapshot; self.sourceOffset = sourceOffset; self.sourceLength = sourceLength
    }
    public func stageSource(in directory: URL, control: WorkControl, progress: @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL? {
        guard let snapshot else { return nil }
        try snapshot.validate()
        let source = try FileHandle(forReadingFrom: snapshot.url), target = directory.appendingPathComponent("xml-image-\(step.id).img"), output = try AtomicOutput(target)
        defer { try? source.close() }
        var done: UInt64 = 0
        while done < sourceLength {
            try control.check()
            let bytes = try source.readExactly(offset: checkedAdd(sourceOffset, done), count: Int(min(1024 * 1024, sourceLength - done)), fileSize: snapshot.size)
            try output.handle.write(contentsOf: bytes); done += UInt64(bytes.count)
            progress(WorkProgress("准备 " + snapshot.url.lastPathComponent, done: done, total: sourceLength))
        }
        try control.check(); try snapshot.validate()
        let file = try output.commit()
        if step.sparse { try SparseImage.inspect(file, control: control).validateContents(control: control) }
        return file
    }
}
