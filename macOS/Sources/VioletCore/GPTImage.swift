import Foundation
import VioletNative

public struct GPTPartition: Identifiable, Codable, Sendable {
    public let index: UInt64
    public let name: String
    public let typeGUID: String
    public let uniqueGUID: String
    public let firstLBA: UInt64
    public let lastLBA: UInt64
    public let attributes: UInt64
    public var id: UInt64 { index }
    public var sectorCount: UInt64 { lastLBA - firstLBA + 1 }
}

public struct GPTHeader: Sendable {
    public let currentLBA: UInt64
    public let alternateLBA: UInt64
    public let firstUsableLBA: UInt64
    public let lastUsableLBA: UInt64
    public let diskGUID: String
    public let entriesLBA: UInt64
    public let entryCount: UInt64
    public let entrySize: UInt64
    public let entriesCRC: UInt32
    public var entryBytes: UInt64 { entryCount * entrySize }

    public static func parse(_ data: Data, sectorSize: UInt64, totalSectors: UInt64, expectedLBA: UInt64) throws -> GPTHeader {
        guard [512,1024,2048,4096,8192,16384,32768,65536].contains(sectorSize), data.count == sectorSize,
              data.prefix(8) == Data("EFI PART".utf8), try data.integer(at: 8, bytes: 4) == 0x10000,
              try data.integer(at: 20, bytes: 4) == 0 else { throw InputError.invalid("GPT header 签名、版本或扇区大小无效。") }
        let headerSize = try data.integer(at: 12, bytes: 4), storedCRC = try data.integer(at: 16, bytes: 4)
        guard headerSize >= 92, headerSize <= sectorSize else { throw InputError.invalid("GPT header_size 无效。") }
        var protectedBytes = Data(data.prefix(Int(headerSize))); protectedBytes.replaceSubrange(16..<20, with: Data(count: 4))
        guard UInt64(crc(protectedBytes)) == storedCRC else { throw InputError.invalid("GPT header CRC32 不匹配。") }
        let current = try data.integer(at: 24, bytes: 8), alternate = try data.integer(at: 32, bytes: 8)
        let first = try data.integer(at: 40, bytes: 8), last = try data.integer(at: 48, bytes: 8)
        let entries = try data.integer(at: 72, bytes: 8), count = try data.integer(at: 80, bytes: 4), size = try data.integer(at: 84, bytes: 4)
        guard totalSectors >= 6, current == expectedLBA, current < totalSectors, alternate < totalSectors, current != alternate,
              first >= 3, first <= last, last < totalSectors - 1, entries >= 2,
              count > 0, count <= 16384, size >= 128, size <= 4096, size % 8 == 0 else { throw InputError.invalid("GPT 几何字段无效。") }
        let bytes = try checkedMultiply(count, size), sectors = try checkedAdd(bytes, sectorSize - 1) / sectorSize
        guard bytes <= 64 * 1024 * 1024, try checkedAdd(entries, sectors) <= totalSectors else { throw InputError.invalid("GPT 分区表超出读取限制或磁盘范围。") }
        let guid = data.subdata(in: 56..<72)
        guard guid.contains(where: { $0 != 0 }) else { throw InputError.invalid("GPT 磁盘 GUID 为空。") }
        return GPTHeader(currentLBA: current, alternateLBA: alternate, firstUsableLBA: first, lastUsableLBA: last,
            diskGUID: guidString(guid), entriesLBA: entries, entryCount: count, entrySize: size,
            entriesCRC: UInt32(try data.integer(at: 88, bytes: 4)))
    }

    func partitions(_ entries: Data) throws -> [GPTPartition] {
        guard entries.count == entryBytes, Self.crc(entries) == entriesCRC else { throw InputError.invalid("GPT 分区条目 CRC32 不匹配。") }
        var partitions: [GPTPartition] = [], guids: Set<String> = []
        for index in 0..<entryCount {
            let offset = Int(index * entrySize), entry = entries.subdata(in: offset..<offset + Int(entrySize))
            let type = entry.subdata(in: 0..<16)
            if type.allSatisfy({ $0 == 0 }) { continue }
            let guid = entry.subdata(in: 16..<32), first = try entry.integer(at: 32, bytes: 8), last = try entry.integer(at: 40, bytes: 8)
            guard first >= firstUsableLBA, last >= first, last <= lastUsableLBA, guid.contains(where: { $0 != 0 }), guids.insert(Self.guidString(guid)).inserted else {
                throw InputError.invalid("GPT 分区越界、GUID 为空或重复。")
            }
            var nameBytes = Data()
            for offset in stride(from: 56, to: 128, by: 2) {
                let pair = entry.subdata(in: offset..<offset + 2)
                if pair == Data([0,0]) { break }
                nameBytes += pair
            }
            guard let name = String(data: nameBytes, encoding: .utf16LittleEndian), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InputError.invalid("GPT 分区名称不是有效 UTF-16。") }
            partitions.append(GPTPartition(index: index + 1, name: name, typeGUID: Self.guidString(type), uniqueGUID: Self.guidString(guid), firstLBA: first, lastLBA: last, attributes: try entry.integer(at: 48, bytes: 8)))
        }
        let ordered = partitions.sorted { $0.firstLBA < $1.firstLBA }
        for (left, right) in zip(ordered, ordered.dropFirst()) where left.lastLBA >= right.firstLBA { throw InputError.invalid("GPT 分区范围重叠：\(left.name) / \(right.name)") }
        return partitions
    }
    static func crc(_ bytes: Data) -> UInt32 { bytes.withUnsafeBytes { violet_crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) } }
    static func guidString(_ bytes: Data) -> String {
        [Data(bytes[0..<4].reversed()).hexString, Data(bytes[4..<6].reversed()).hexString, Data(bytes[6..<8].reversed()).hexString,
         bytes.subdata(in: 8..<10).hexString, bytes.subdata(in: 10..<16).hexString].joined(separator: "-")
    }
}

public struct GPTDiskImage: Sendable {
    public let sectorSize: UInt64
    public let totalSectors: UInt64
    public let header: GPTHeader
    public let backupHeader: GPTHeader
    public let partitions: [GPTPartition]
    public let mainBytes: Data
    public let backupBytes: Data
    public var backupStartLBA: UInt64 { backupHeader.entriesLBA }
    public var warning: String? { header.alternateLBA == totalSectors - 1 ? nil : "备份 GPT 不在物理磁盘最后扇区，请核对磁盘容量与布局。" }
    public typealias Reader = @Sendable (UInt64, UInt64) async throws -> Data

    public static func read(sectorSize: UInt64, totalSectors: UInt64, control: WorkControl = WorkControl(), reader: Reader) async throws -> GPTDiskImage? {
        guard [512,1024,2048,4096,8192,16384,32768,65536].contains(sectorSize), totalSectors >= 6 else { throw InputError.invalid("GPT 设备几何信息无效。") }
        func read(_ lba: UInt64, _ sectors: UInt64) async throws -> Data {
            try control.check()
            let size = try checkedMultiply(sectorSize, sectors)
            guard sectors > 0, lba < totalSectors, sectors <= totalSectors - lba, size <= 64 * 1024 * 1024 else { throw InputError.invalid("GPT 读取范围过大或越界。") }
            let data = try await reader(lba, sectors)
            try control.check()
            guard UInt64(data.count) == size else { throw InputError.invalid("GPT 回读长度不足。") }
            return data
        }
        let initial = try await read(0, 2)
        guard initial.subdata(in: Int(sectorSize)..<Int(sectorSize) + 8) == Data("EFI PART".utf8) else { return nil }
        let primary = try GPTHeader.parse(initial.subdata(in: Int(sectorSize)..<initial.count), sectorSize: sectorSize, totalSectors: totalSectors, expectedLBA: 1)
        let entriesSectors = (primary.entryBytes + sectorSize - 1) / sectorSize
        guard primary.entriesLBA + entriesSectors <= primary.firstUsableLBA, primary.lastUsableLBA < primary.alternateLBA else { throw InputError.invalid("GPT 主表区域与可用分区重叠。") }
        let mainSectors = try checkedAdd(primary.entriesLBA, entriesSectors)
        let main = try await read(0, mainSectors)
        let primaryAgain = try GPTHeader.parse(main.subdata(in: Int(sectorSize)..<Int(sectorSize * 2)), sectorSize: sectorSize, totalSectors: totalSectors, expectedLBA: 1)
        guard primaryAgain.diskGUID == primary.diskGUID, primaryAgain.entriesCRC == primary.entriesCRC,
              main.subdata(in: Int(sectorSize)..<Int(sectorSize * 2)) == initial.subdata(in: Int(sectorSize)..<initial.count) else { throw InputError.invalid("读取期间 GPT header 已变化。") }
        let backupHeaderBytes = try await read(primary.alternateLBA, 1)
        let backup = try GPTHeader.parse(backupHeaderBytes, sectorSize: sectorSize, totalSectors: totalSectors, expectedLBA: primary.alternateLBA)
        guard backup.alternateLBA == 1, backup.diskGUID == primary.diskGUID, backup.firstUsableLBA == primary.firstUsableLBA,
              backup.lastUsableLBA == primary.lastUsableLBA, backup.entryCount == primary.entryCount, backup.entrySize == primary.entrySize,
              backup.entriesLBA > primary.lastUsableLBA, try checkedAdd(backup.entriesLBA, entriesSectors) <= backup.currentLBA else { throw InputError.invalid("GPT 主表与备份表几何信息不一致。") }
        let backupRegion = try await read(backup.entriesLBA, backup.currentLBA - backup.entriesLBA + 1)
        let primaryOffset = Int(primary.entriesLBA * sectorSize), entryBytes = Int(primary.entryBytes)
        let primaryEntries = main.subdata(in: primaryOffset..<primaryOffset + entryBytes)
        let backupEntries = backupRegion.subdata(in: 0..<entryBytes)
        let headerOffset = Int((backup.currentLBA - backup.entriesLBA) * sectorSize)
        guard backupRegion.subdata(in: headerOffset..<headerOffset + Int(sectorSize)) == backupHeaderBytes else { throw InputError.invalid("读取期间 GPT 备份 header 已变化。") }
        let partitions = try primary.partitions(primaryEntries)
        _ = try backup.partitions(backupEntries)
        guard primaryEntries == backupEntries else { throw InputError.invalid("GPT 主表与备份分区条目不一致。") }
        return GPTDiskImage(sectorSize: sectorSize, totalSectors: totalSectors, header: primary, backupHeader: backup,
            partitions: partitions, mainBytes: main, backupBytes: backupRegion)
    }

    public static func open(_ url: URL, sectorSize: UInt64 = 512, control: WorkControl = WorkControl()) async throws -> GPTDiskImage {
        let snapshot = try FileSnapshot(url)
        guard sectorSize > 0, snapshot.size % sectorSize == 0 else { throw InputError.invalid("磁盘镜像大小未按扇区对齐。") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let result = try await read(sectorSize: sectorSize, totalSectors: snapshot.size / sectorSize, control: control) { lba, sectors in
            try file.readExactly(offset: lba * sectorSize, count: Int(sectors * sectorSize), fileSize: snapshot.size)
        }
        try snapshot.validate()
        guard let result else { throw InputError.invalid("磁盘镜像没有 GPT 签名。") }
        return result
    }

    public func export(to directory: URL, prefix: String, lun: UInt64? = nil, control: WorkControl = WorkControl()) throws -> [URL] {
        let prefix = try Input.partition(prefix)
        var files: [URL] = []
        let mainName = lun.map { "gpt_main\($0).bin" } ?? prefix + "_main.bin"
        let backupName = lun.map { "gpt_backup\($0).bin" } ?? prefix + "_backup.bin"
        for (name, bytes) in [(mainName,mainBytes),(backupName,backupBytes)] {
            try control.check()
            let output = try AtomicOutput(directory.appendingPathComponent(name)); try output.handle.write(contentsOf: bytes)
            try control.check(); files.append(try output.commit())
        }
        struct Metadata: Encodable { let sectorSize: UInt64; let totalSectors: UInt64; let diskGUID: String; let backupStartLBA: UInt64; let partitions: [GPTPartition] }
        let metadata = Metadata(sectorSize: sectorSize, totalSectors: totalSectors, diskGUID: header.diskGUID, backupStartLBA: backupStartLBA, partitions: partitions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let output = try AtomicOutput(directory.appendingPathComponent(prefix + ".json")); try output.handle.write(contentsOf: encoder.encode(metadata))
        try control.check(); files.append(try output.commit())
        return files
    }
}
