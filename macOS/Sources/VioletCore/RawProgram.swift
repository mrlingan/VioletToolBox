import Foundation

public struct RawProgramEntry: Sendable {
    public let filename: String
    public let label: String
    public let lun: UInt64
    public let sectorSize: UInt64
    public let startSector: UInt64
    public let sectorCount: UInt64
    public init(filename: String, label: String, lun: UInt64, sectorSize: UInt64, startSector: UInt64, sectorCount: UInt64) throws {
        self.filename = try ArchivePaths.normalize(filename)
        guard lun <= 255, [512,1024,2048,4096,8192,16384,32768,65536].contains(sectorSize), sectorCount > 0,
              label.utf8.count <= 1024, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InputError.invalid("rawprogram 条目字段无效。") }
        _ = try checkedMultiply(checkedAdd(startSector, sectorCount), sectorSize)
        self.label = label; self.lun = lun; self.sectorSize = sectorSize; self.startSector = startSector; self.sectorCount = sectorCount
    }
}

public enum RawProgram {
    public struct PartitionMap: Sendable {
        public let lun: UInt64
        public let sectorSize: UInt64
        public let partitions: [GPTPartition]
        public init(lun: UInt64, sectorSize: UInt64, partitions: [GPTPartition]) { self.lun = lun; self.sectorSize = sectorSize; self.partitions = partitions }
    }
    public static func partitionEntries(images: [String: URL], maps: [PartitionMap]) throws -> [RawProgramEntry] {
        try images.keys.sorted().map { name in
            let matches = maps.flatMap { map in map.partitions.filter { $0.name == name }.map { (map,$0) } }
            guard matches.count == 1 else { throw InputError.invalid("\(name)：物理 GPT 中未找到唯一匹配，不能生成还原 XML。") }
            let (map, partition) = matches[0], file = try FileSnapshot(images[name]!)
            guard file.size == (try checkedMultiply(partition.sectorCount, map.sectorSize)) else { throw InputError.invalid("\(name)：镜像大小与物理 GPT 不一致，不能生成还原 XML。") }
            return try RawProgramEntry(filename: file.url.lastPathComponent, label: name, lun: map.lun, sectorSize: map.sectorSize, startSector: partition.firstLBA, sectorCount: partition.sectorCount)
        }
    }
    public static func encode(_ entries: [RawProgramEntry]) throws -> Data {
        guard !entries.isEmpty, entries.count <= 16384 else { throw InputError.invalid("rawprogram 条目数无效。") }
        let root = XMLElement(name: "data")
        for entry in entries.sorted(by: { $0.lun == $1.lun ? $0.startSector < $1.startSector : $0.lun < $1.lun }) {
            let size = try checkedMultiply(entry.sectorCount, entry.sectorSize)
            let attributes = [
                "SECTOR_SIZE_IN_BYTES":String(entry.sectorSize), "file_sector_offset":"0", "filename":entry.filename,
                "label":entry.label, "num_partition_sectors":String(entry.sectorCount), "physical_partition_number":String(entry.lun),
                "size_in_KB":NSDecimalNumber(decimal: Decimal(size) / 1024).stringValue, "sparse":"false",
                "start_byte_hex":"0x" + String(try checkedMultiply(entry.startSector, entry.sectorSize), radix: 16).uppercased(), "start_sector":String(entry.startSector)
            ]
            let node = XMLElement(name: "program")
            for key in attributes.keys.sorted() { node.addAttribute(XMLNode.attribute(withName: key, stringValue: attributes[key]!) as! XMLNode) }
            root.addChild(node)
        }
        let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "UTF-8"
        return document.xmlData(options: .nodePrettyPrint)
    }
    public static func write(_ entries: [RawProgramEntry], to target: URL) throws -> URL {
        let output = try AtomicOutput(target); try output.handle.write(contentsOf: encode(entries)); return try output.commit()
    }
}
