import Foundation

/// Reads the same ELF64 / last PT_NULL / OEM metadata fields as the Windows
/// ParseXblConfigArb implementation. This is an image index, not a fuse reader.
public struct XBLARBImage: Sendable {
    public let majorVersion: UInt32
    public let minorVersion: UInt32
    public let index: UInt32
    public let hashSegmentOffset: UInt64
    public let oemMetadataOffset: UInt64

    public static func inspect(_ source: URL, control: WorkControl = WorkControl()) throws -> XBLARBImage {
        let snapshot = try FileSnapshot(source), handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try control.check()
        guard snapshot.size >= 64 else { throw InputError.invalid("文件过小，不是有效 xbl_config ELF。") }
        let header = try handle.readExactly(offset: 0, count: 64, fileSize: snapshot.size)
        guard header.prefix(4) == Data([0x7f,0x45,0x4c,0x46]), header[4] == 2, header[5] == 1 else { throw InputError.invalid("仅支持小端 ELF64 xbl_config 镜像。") }
        let table = try header.integer(at: 0x20, bytes: 8), entrySize = try header.integer(at: 0x36, bytes: 2), count = try header.integer(at: 0x38, bytes: 2)
        guard entrySize >= 56, count > 0 else { throw InputError.invalid("ELF 程序头目录无效。") }
        let tableEnd = try checkedAdd(table, checkedMultiply(count, entrySize))
        guard tableEnd <= snapshot.size else { throw InputError.invalid("ELF 程序头目录越界。") }
        var segmentOffset: UInt64 = 0, segmentSize: UInt64 = 0
        for entry in stride(from: Int(count) - 1, through: 0, by: -1) {
            try control.check()
            let offset = try checkedAdd(table, checkedMultiply(UInt64(entry), entrySize))
            let bytes = try handle.readExactly(offset: offset, count: 56, fileSize: snapshot.size)
            let type = try bytes.integer(at: 0, bytes: 4), size = try bytes.integer(at: 0x20, bytes: 8)
            if type == 0 && size > 0 { segmentOffset = try bytes.integer(at: 8, bytes: 8); segmentSize = size; break }
        }
        guard segmentSize > 0, segmentOffset <= snapshot.size, segmentSize <= snapshot.size - segmentOffset else { throw InputError.invalid("未找到有效的 xbl_config HASH 段，或段范围越界。") }
        // Header search is bounded to the first 0x1000 bytes. OEM data is read
        // by offset, so even a large segment is never loaded into memory.
        let prefix = try handle.readExactly(offset: segmentOffset, count: Int(min(segmentSize, 4096 + 36)), fileSize: snapshot.size)
        var found: (offset: UInt64, common: UInt64, qti: UInt64)?
        for offset in stride(from: 0, to: 4096, by: 4) {
            try control.check()
            guard offset + 36 <= prefix.count else { break }
            let version = try prefix.integer(at: offset, bytes: 4), common = try prefix.integer(at: offset + 4, bytes: 4)
            let qti = try prefix.integer(at: offset + 8, bytes: 4), oem = try prefix.integer(at: offset + 12, bytes: 4), hashes = try prefix.integer(at: offset + 16, bytes: 4)
            guard (1...10).contains(version), common <= 0x1000, oem >= 12, oem <= 0x4000, hashes <= 0x4000 else { continue }
            let end = try checkedAdd(checkedAdd(UInt64(offset) + 36, common), checkedAdd(qti, oem))
            guard end <= segmentSize else { continue }
            found = (UInt64(offset), common, qti); break
        }
        guard let found else { throw InputError.invalid("未找到 HASH Table Segment Header。") }
        let relative = try checkedAdd(checkedAdd(found.offset + 36, found.common), found.qti), oemOffset = try checkedAdd(segmentOffset, relative)
        guard relative <= segmentSize, 12 <= segmentSize - relative else { throw InputError.invalid("OEM 元数据范围无效。") }
        let metadata = try handle.readExactly(offset: oemOffset, count: 12, fileSize: snapshot.size)
        try control.check(); try snapshot.validate()
        return XBLARBImage(majorVersion: UInt32(try metadata.integer(at: 0, bytes: 4)), minorVersion: UInt32(try metadata.integer(at: 4, bytes: 4)), index: UInt32(try metadata.integer(at: 8, bytes: 4)), hashSegmentOffset: segmentOffset, oemMetadataOffset: oemOffset)
    }
}
