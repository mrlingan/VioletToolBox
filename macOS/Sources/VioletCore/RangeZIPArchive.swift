import Foundation
import CryptoKit
import VioletNative

public struct RangeZIPEntry: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let compressedSize: UInt64
    public let size: UInt64
    public let method: UInt64
    public let isDirectory: Bool
    public let unsupportedReason: String?
    public var extractable: Bool { !isDirectory && unsupportedReason == nil }
    fileprivate let rawName: Data
    fileprivate let flags: UInt64
    fileprivate let crc: UInt32
    fileprivate let headerOffset: UInt64
}

// ZIP/ZIP64 central-directory reads work with local files and HTTP Range alike.
// No entry pathname is interpreted as a command or followed as a symlink.
public struct RangeZIPArchive: Sendable {
    public let entries: [RangeZIPEntry]
    private let source: any FirmwareByteSource
    private let directoryOffset: UInt64
    private let directorySize: Int
    private let directoryHash: Data

    public static func open(_ source: any FirmwareByteSource, control: WorkControl = WorkControl()) async throws -> RangeZIPArchive {
        try control.check()
        guard source.size >= 22 else { throw InputError.invalid("ZIP 太小，缺少目录尾记录。") }
        let tailSize = Int(min(source.size,65557)), tailOffset = source.size-UInt64(tailSize)
        let tail = try await source.read(offset:tailOffset,count:tailSize,control:control)
        var eocd: Int?
        for offset in stride(from:tail.count-22,through:0,by:-1) {
            if tail[offset] == 0x50, try tail.integer(at:offset,bytes:4) == 0x06054b50,
               try tail.integer(at:offset+20,bytes:2) == UInt64(tail.count-offset-22) { eocd = offset; break }
        }
        guard let eocd else { throw InputError.invalid("ZIP 缺少有效 EOCD，或注释长度不符。") }
        let endOffset = tailOffset+UInt64(eocd)
        guard try tail.integer(at:eocd+4,bytes:2) == 0, try tail.integer(at:eocd+6,bytes:2) == 0 else { throw InputError.invalid("不支持跨磁盘 ZIP。") }
        var count = try tail.integer(at:eocd+10,bytes:2)
        guard try tail.integer(at:eocd+8,bytes:2) == count else { throw InputError.invalid("ZIP 分卷条目计数不符。") }
        var directorySize = try tail.integer(at:eocd+12,bytes:4), directoryOffset = try tail.integer(at:eocd+16,bytes:4), bound = endOffset
        if count == 0xffff || directorySize == 0xffffffff || directoryOffset == 0xffffffff {
            guard endOffset >= 20 else { throw InputError.invalid("ZIP64 Locator 已截断。") }
            let locator = try await source.read(offset:endOffset-20,count:20,control:control)
            guard try locator.integer(at:0,bytes:4) == 0x07064b50, try locator.integer(at:4,bytes:4) == 0, try locator.integer(at:16,bytes:4) == 1 else { throw InputError.invalid("ZIP64 Locator 无效或为分卷。") }
            let offset = try locator.integer(at:8,bytes:8)
            guard offset <= endOffset-20, endOffset-20-offset >= 56 else { throw InputError.invalid("ZIP64 EOCD 范围无效。") }
            let record = try await source.read(offset:offset,count:56,control:control)
            let length = try record.integer(at:4,bytes:8)
            guard try record.integer(at:0,bytes:4) == 0x06064b50, length >= 44, length <= endOffset-20-offset-12,
                  try record.integer(at:16,bytes:4) == 0, try record.integer(at:20,bytes:4) == 0 else { throw InputError.invalid("ZIP64 EOCD 无效。") }
            count = try record.integer(at:32,bytes:8)
            guard try record.integer(at:24,bytes:8) == count else { throw InputError.invalid("ZIP64 条目计数不符。") }
            directorySize = try record.integer(at:40,bytes:8); directoryOffset = try record.integer(at:48,bytes:8); bound = offset
        }
        guard count <= 100_000, directorySize <= 64*1024*1024, directoryOffset <= bound, directorySize <= bound-directoryOffset,
              count <= directorySize/46 else { throw InputError.invalid("ZIP 目录范围、大小或条目计数无效。") }
        let directory = try await source.read(offset:directoryOffset,count:Int(directorySize),control:control)
        var entries: [RangeZIPEntry] = [], names: Set<String> = [], cursor = 0
        for _ in 0..<count {
            try control.check()
            guard cursor <= directory.count-46, try directory.integer(at:cursor,bytes:4) == 0x02014b50 else { throw InputError.invalid("ZIP 中央目录条目已截断。") }
            func number(_ offset: Int, _ bytes: Int) throws -> UInt64 { try directory.integer(at:cursor+offset,bytes:bytes) }
            let flags = try number(8,2), method = try number(10,2), crc = UInt32(try number(16,4))
            var compressed = try number(20,4), size = try number(24,4), local = try number(42,4), disk = try number(34,2)
            let nameSize = Int(try number(28,2)), extraSize = Int(try number(30,2)), commentSize = Int(try number(32,2))
            let recordSize = 46+nameSize+extraSize+commentSize
            guard nameSize > 0, recordSize <= directory.count-cursor else { throw InputError.invalid("ZIP 目录名称或额外字段越界。") }
            let rawName = directory.subdata(in:cursor+46..<cursor+46+nameSize)
            guard let decoded = String(data:rawName,encoding:.utf8) ?? (flags & 0x800 == 0 ? String(data:rawName,encoding:.isoLatin1) : nil), !decoded.contains("\\") else { throw InputError.invalid("ZIP 名称不是有效 UTF-8 或包含非标准路径分隔符。") }
            let isDirectory = decoded.hasSuffix("/")
            let name = try ArchivePaths.normalize(isDirectory ? String(decoded.dropLast()) : decoded)
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw InputError.invalid("ZIP 含重复或大小写冲突路径：\(name)") }
            let extraStart = cursor+46+nameSize, extraEnd = extraStart+extraSize
            var extra = extraStart, zip64: Data?
            while extra < extraEnd {
                guard extraEnd-extra >= 4 else { throw InputError.invalid("ZIP 额外字段已截断。") }
                let tag = try directory.integer(at:extra,bytes:2), length = Int(try directory.integer(at:extra+2,bytes:2))
                guard length <= extraEnd-extra-4 else { throw InputError.invalid("ZIP 额外字段长度无效。") }
                if tag == 1 { guard zip64 == nil else { throw InputError.invalid("ZIP64 额外字段重复。") }; zip64 = directory.subdata(in:extra+4..<extra+4+length) }
                extra += 4+length
            }
            if compressed == 0xffffffff || size == 0xffffffff || local == 0xffffffff || disk == 0xffff {
                guard let zip64 else { throw InputError.invalid("ZIP 条目缺少 ZIP64 大小 / 偏移。") }
                var position = 0
                func next(_ width: Int = 8) throws -> UInt64 { defer { position += width }; return try zip64.integer(at:position,bytes:width) }
                if size == 0xffffffff { size = try next() }
                if compressed == 0xffffffff { compressed = try next() }
                if local == 0xffffffff { local = try next() }
                if disk == 0xffff { disk = try next(4) }
            }
            guard disk == 0, local <= directoryOffset, directoryOffset-local >= 30, size <= 1<<40, compressed <= directoryOffset-local-30 else { throw InputError.invalid("ZIP 文件数据范围无效或为分卷。") }
            let platform = try number(4,2) >> 8, mode = try number(38,4) >> 16 & 0xf000
            let kindUnsupported = platform == 3 && mode != 0 && mode != 0x8000 && mode != 0x4000
            let reason: String? = flags & 0x2041 != 0 ? "加密 ZIP 条目" : kindUnsupported ? "符号链接或特殊文件" : ![0,8].contains(method) ? "压缩方法 \(method)" : method == 0 && size != compressed ? "Stored 长度不一致" : nil
            entries.append(RangeZIPEntry(name:name,compressedSize:compressed,size:size,method:method,isDirectory:isDirectory,unsupportedReason:reason,rawName:rawName,flags:flags,crc:crc,headerOffset:local))
            cursor += recordSize
        }
        if cursor != directory.count {
            guard directory.count-cursor >= 6, try directory.integer(at:cursor,bytes:4) == 0x05054b50,
                  try directory.integer(at:cursor+4,bytes:2) == UInt64(directory.count-cursor-6) else { throw InputError.invalid("ZIP 中央目录含未识别的尾部数据。") }
        }
        return RangeZIPArchive(entries:entries,source:source,directoryOffset:directoryOffset,directorySize:Int(directorySize),directoryHash:Data(SHA256.hash(data:directory)))
    }
    public func entry(named name: String) -> RangeZIPEntry? { entries.first { $0.name == name } }
    public func payloadEntry() throws -> RangeZIPEntry? {
        let found = entries.filter { !$0.isDirectory && ($0.name as NSString).lastPathComponent.lowercased() == "payload.bin" }
        guard found.count <= 1 else { throw InputError.invalid("ZIP 含多个 payload.bin，无法唯一选择。") }
        return found.first
    }
    public func validate(control: WorkControl) async throws {
        if let remote = source as? HTTPRangeSource, remote.hasValidator { _ = try await source.read(offset:0,count:1,control:control) }
        else {
            let current = try await source.read(offset:directoryOffset,count:directorySize,control:control)
            guard Data(SHA256.hash(data:current)) == directoryHash else { throw InputError.invalid("ZIP 目录已变化，请重新打开。") }
        }
    }
    public func storedSource(for entry: RangeZIPEntry, control: WorkControl) async throws -> any FirmwareByteSource {
        guard entry.extractable, entry.method == 0 else { throw InputError.invalid("远程 Payload 需为未加密 Stored 条目；压缩的 payload.bin 请先完整下载解压。") }
        let offset = try await dataOffset(for:entry,control:control)
        return try BoundedByteSource(parent:source,offset:offset,size:entry.size)
    }
    public func contents(of entry: RangeZIPEntry, limit: Int = 4*1024*1024, control: WorkControl = WorkControl()) async throws -> Data {
        guard limit >= 0, limit <= 64*1024*1024, entry.size <= UInt64(limit) else { throw InputError.invalid("ZIP 条目超过内存读取上限。") }
        var data = Data()
        try await stream(entry,control:control) { bytes in data.append(bytes) }
        return data
    }
    public func extract(names: Set<String>, to root: URL, control: WorkControl = WorkControl(), progress: @escaping @Sendable (WorkProgress)->Void = { _ in }) async throws -> [URL] {
        let selected = entries.filter { names.contains($0.name) }
        guard !selected.isEmpty, selected.count == names.count, selected.allSatisfy(\.extractable) else { throw InputError.invalid("请选择可提取的普通 ZIP 文件。") }
        try await validate(control:control)
        let total = try selected.reduce(UInt64(0)) { try checkedAdd($0,$1.size) }
        var files: [URL] = [], done: UInt64 = 0
        for entry in selected {
            try control.check()
            let target = try ArchivePaths.destination(root:root,name:entry.name,createParents:true), output = try AtomicOutput(target)
            var written: UInt64 = 0
            try await stream(entry,control:control) { bytes in
                try output.handle.write(contentsOf:bytes); written += UInt64(bytes.count)
                progress(WorkProgress("提取 \(entry.name)",done:done+written,total:total))
            }
            try await validate(control:control); try control.check()
            files.append(try output.commit()); done += entry.size
        }
        return files
    }
    private func dataOffset(for entry: RangeZIPEntry, control: WorkControl) async throws -> UInt64 {
        guard entries.contains(where: { $0.name == entry.name && $0.headerOffset == entry.headerOffset }), entry.extractable else { throw InputError.invalid("ZIP 条目不属于当前目录或不可提取。") }
        let header = try await source.read(offset:entry.headerOffset,count:30,control:control)
        guard try header.integer(at:0,bytes:4) == 0x04034b50, try header.integer(at:6,bytes:2) == entry.flags, try header.integer(at:8,bytes:2) == entry.method else { throw InputError.invalid("ZIP 本地文件头与目录不一致。") }
        let nameSize = try header.integer(at:26,bytes:2), extra = try header.integer(at:28,bytes:2)
        let offset = try checkedAdd(checkedAdd(entry.headerOffset,30),checkedAdd(nameSize,extra))
        guard nameSize == UInt64(entry.rawName.count), offset <= directoryOffset, entry.compressedSize <= directoryOffset-offset else { throw InputError.invalid("ZIP 条目数据范围越界。") }
        let name = try await source.read(offset:entry.headerOffset+30,count:Int(nameSize),control:control)
        guard name == entry.rawName else { throw InputError.invalid("ZIP 本地名称与目录不一致。") }
        return offset
    }
    private func stream(_ entry: RangeZIPEntry, control: WorkControl, receive: (Data) throws -> Void) async throws {
        let start = try await dataOffset(for:entry,control:control)
        let inflater = entry.method == 8 ? try ZIPInflater() : nil
        var position: UInt64 = 0, emitted: UInt64 = 0, crc: UInt32 = 0
        func emit(_ bytes: Data) throws {
            try control.check()
            guard UInt64(bytes.count) <= entry.size-emitted else { throw InputError.invalid("ZIP 解压长度超过声明值。") }
            crc = bytes.withUnsafeBytes { violet_crc32(crc,$0.bindMemory(to:UInt8.self).baseAddress,$0.count) }
            try receive(bytes); emitted += UInt64(bytes.count)
        }
        while position < entry.compressedSize {
            let count = Int(min(1024*1024,entry.compressedSize-position))
            let bytes = try await source.read(offset:start+position,count:count,control:control)
            if let inflater {
                guard !inflater.ended else { throw InputError.invalid("ZIP Deflate 流提前结束或含尾随数据。") }
                try inflater.consume(bytes,control:control,receive:emit)
            } else { try emit(bytes) }
            position += UInt64(bytes.count)
        }
        guard inflater == nil || inflater!.ended, emitted == entry.size, crc == entry.crc else { throw InputError.invalid("ZIP 条目长度、Deflate 结束或 CRC32 校验失败：\(entry.name)") }
        try control.check()
    }
}

public struct BoundedByteSource: FirmwareByteSource {
    public let size: UInt64
    private let parent: any FirmwareByteSource
    private let offset: UInt64
    public init(parent: any FirmwareByteSource, offset: UInt64, size: UInt64) throws {
        guard offset <= parent.size, size <= parent.size-offset else { throw InputError.invalid("文件子范围越界。") }
        self.parent = parent; self.offset = offset; self.size = size
    }
    public func read(offset: UInt64, count: Int, control: WorkControl) async throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size-offset else { throw InputError.invalid("文件子范围读取越界。") }
        return try await parent.read(offset:self.offset+offset,count:count,control:control)
    }
}

private final class ZIPInflater {
    private let context: UnsafeMutableRawPointer
    private(set) var ended = false
    init() throws { guard let context = violet_inflate_create() else { throw InputError.invalid("无法初始化 Deflate。") }; self.context = context }
    deinit { violet_inflate_free(context) }
    func consume(_ bytes: Data, control: WorkControl, receive: (Data) throws -> Void) throws {
        var consumed = 0, output = Data(count:1024*1024)
        while true {
            try control.check()
            var used = 0, written = 0
            let status = bytes.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in
                violet_inflate_update(context,input.bindMemory(to:UInt8.self).baseAddress?.advanced(by:consumed),input.count-consumed,out.bindMemory(to:UInt8.self).baseAddress,out.count,&used,&written)
            } }
            guard status >= 0 else { throw InputError.invalid("ZIP Deflate 解压失败。") }
            consumed += used
            if written > 0 { try receive(Data(output.prefix(written))) }
            if status == 1 { ended = true; guard consumed == bytes.count else { throw InputError.invalid("ZIP Deflate 含尾随压缩数据。") }; return }
            if consumed == bytes.count, written < output.count { return }
            guard used > 0 || written > 0 else { throw InputError.invalid("ZIP Deflate 流无法推进。") }
        }
    }
}
