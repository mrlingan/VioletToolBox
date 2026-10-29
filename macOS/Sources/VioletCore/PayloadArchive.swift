import Foundation
import CryptoKit
import VioletNative

// Field numbers and operation types follow AOSP update_engine/update_metadata.proto.
// https://android.googlesource.com/platform/system/update_engine/+/refs/heads/main/update_metadata.proto
private enum ProtoValue { case number(UInt64), bytes(Data) }
private struct ProtoMessage {
    var fields: [Int: [ProtoValue]] = [:]
    init(_ data: Data) throws {
        var cursor = 0, fieldCount = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < data.count else { throw InputError.invalid("Payload protobuf 不完整。") }
                let byte = data[data.startIndex + cursor]; cursor += 1
                guard index < 9 || byte <= 1 else { throw InputError.invalid("Payload protobuf 整数溢出。") }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte < 128 { return value }
            }
            throw InputError.invalid("Payload protobuf 整数无效。")
        }
        while cursor < data.count {
            fieldCount += 1
            guard fieldCount <= 400_000 else { throw InputError.invalid("Payload 元数据字段过多。") }
            let tag = try varint(), wire = tag & 7
            guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw InputError.invalid("Payload protobuf 字段无效。") }
            let field = Int(tag >> 3)
            if wire == 0 { fields[field, default: []].append(.number(try varint())) }
            else if wire == 2 {
                let length = try varint()
                guard length <= UInt64(data.count - cursor) else { throw InputError.invalid("Payload protobuf 长度无效。") }
                fields[field, default: []].append(.bytes(data.subdata(in: cursor..<(cursor + Int(length)))))
                cursor += Int(length)
            } else if wire == 1 || wire == 5 {
                let length = wire == 1 ? 8 : 4
                guard length <= data.count - cursor else { throw InputError.invalid("Payload protobuf 字段已截断。") }
                cursor += length
            } else { throw InputError.invalid("不支持的 Payload protobuf 编码。") }
        }
    }
    func number(_ key: Int, default fallback: UInt64 = 0) -> UInt64 {
        if case let .number(value)? = fields[key]?.last { return value }; return fallback
    }
    func bytes(_ key: Int) -> Data? { if case let .bytes(value)? = fields[key]?.last { return value }; return nil }
    func messages(_ key: Int) throws -> [ProtoMessage] {
        try (fields[key] ?? []).map { value in
            guard case let .bytes(data) = value else { throw InputError.invalid("Payload 嵌套字段类型错误。") }
            return try ProtoMessage(data)
        }
    }
}

public struct PayloadPartition: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: UInt64
    public let operationCount: Int
    public let unsupportedTypes: [UInt64]
    public let requiresSource: Bool
    public var extractable: Bool { unsupportedTypes.isEmpty && !requiresSource }
    public var hasSHA256: Bool { expectedHash != nil }
    let operations: [PayloadOperation]
    let expectedHash: Data?
}

struct PayloadExtent: Sendable { let start: UInt64; let size: UInt64 }
struct PayloadOperation: Sendable {
    let type: UInt64
    let offset: UInt64
    let length: UInt64
    let extents: [PayloadExtent]
    let hash: Data?
}

private final class ZIPProgressContext {
    let control: WorkControl
    let report: @Sendable (WorkProgress) -> Void
    init(_ control: WorkControl, _ report: @escaping @Sendable (WorkProgress) -> Void) { self.control = control; self.report = report }
}

public struct PayloadArchive: Sendable {
    public let originalURL: URL
    public let sourceURL: URL
    public let partitions: [PayloadPartition]
    public let blockSize: UInt64
    public let fileSize: UInt64
    public let isTemporary: Bool
    private let dataOffset: UInt64
    private let snapshot: FileSnapshot

    public static func open(_ url: URL, control: WorkControl = WorkControl(),
                            progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> PayloadArchive {
        try control.check()
        let originalSnapshot = try FileSnapshot(url)
        let handle = try FileHandle(forReadingFrom: url)
        let signature = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        var source = url, temporary = false
        if signature.starts(with: [0x50, 0x4b]) {
            source = FileManager.default.temporaryDirectory.appendingPathComponent("violet-payload-" + UUID().uuidString + ".bin")
            let context = ZIPProgressContext(control, progress)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            defer { Unmanaged<ZIPProgressContext>.fromOpaque(pointer).release() }
            var error = [CChar](repeating: 0, count: 1024)
            let result = violet_extract_payload(url.path, source.path, { pointer, done, total in
                guard let pointer else { return 1 }
                let context = Unmanaged<ZIPProgressContext>.fromOpaque(pointer).takeUnretainedValue()
                context.report(WorkProgress("正在解压 OTA ZIP", done: UInt64(max(0, done)), total: UInt64(max(0, total))))
                return context.control.isCancelled ? 1 : 0
            }, pointer, &error, error.count)
            if result == -2 { throw CancellationError() }
            guard result == 0 else { throw InputError.invalid(String(cString: error)) }
            temporary = true
        }
        do { try originalSnapshot.validate(); return try parse(source, original: url, temporary: temporary, control: control) }
        catch { if temporary { try? FileManager.default.removeItem(at: source) }; throw error }
    }

    private static func parse(_ url: URL, original: URL, temporary: Bool, control: WorkControl) throws -> PayloadArchive {
        let snapshot = try FileSnapshot(url), size = snapshot.size
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.readExactly(offset: 0, count: 24, fileSize: size)
        let metadata = try PayloadMetadataHeader(header,fileSize:size)
        let manifest = try input.readExactly(offset:24,count:Int(metadata.manifestSize),fileSize:size)
        let layout = try parseManifest(header:header,manifestBytes:manifest,fileSize:size,control:control)
        try snapshot.validate()
        return PayloadArchive(originalURL:original,sourceURL:url,partitions:layout.partitions,blockSize:layout.blockSize,fileSize:size,isTemporary:temporary,dataOffset:layout.dataOffset,snapshot:snapshot)
    }

    static func parseManifest(header: Data, manifestBytes: Data, fileSize size: UInt64, control: WorkControl) throws -> PayloadLayout {
        let metadata = try PayloadMetadataHeader(header,fileSize:size), dataOffset = metadata.dataOffset
        guard UInt64(manifestBytes.count) == metadata.manifestSize else { throw InputError.invalid("Payload manifest 读取不完整。") }
        let manifest = try ProtoMessage(manifestBytes)
        let block = manifest.number(3, default: 4096)
        guard block >= 512, block <= 1024 * 1024, block & (block - 1) == 0 else { throw InputError.invalid("Payload block_size 无效。") }
        var partitions: [PayloadPartition] = [], names: Set<String> = []
        let updates = try manifest.messages(13)
        guard !updates.isEmpty, updates.count <= 1024 else { throw InputError.invalid("Payload 分区列表为空或过大。") }
        for update in updates {
            try control.check()
            guard let rawName = update.bytes(1), let name = String(data: rawName, encoding: .utf8) else { throw InputError.invalid("Payload 分区名无效。") }
            _ = try Input.partition(name)
            guard names.insert(name.lowercased()).inserted else { throw InputError.invalid("Payload 存在重复或大小写冲突分区：\(name)") }
            let info = try update.bytes(7).map(ProtoMessage.init)
            let partitionHash = info?.bytes(2)
            if let partitionHash, partitionHash.count != 32 { throw InputError.invalid("分区 SHA-256 长度无效。") }
            var operations: [PayloadOperation] = [], end: UInt64 = 0, ranges: [Range<UInt64>] = []
            var requiresSource = false
            let opMessages = try update.messages(8)
            guard !opMessages.isEmpty, opMessages.count <= 200_000 else { throw InputError.invalid("分区操作列表为空或过大。") }
            for op in opMessages {
                try control.check()
                let type = op.number(1, default: UInt64.max)
                let offset = op.number(2), length = op.number(3)
                guard length <= size, try checkedAdd(offset, length) <= size - dataOffset else { throw InputError.invalid("Payload 操作数据超出文件范围。") }
                if [6,7].contains(type), length != 0 { throw InputError.invalid("ZERO / DISCARD 操作包含非空输入。") }
                if let sourceHash = op.bytes(9), !sourceHash.isEmpty {
                    guard sourceHash.count == 32 else { throw InputError.invalid("源分区 SHA-256 长度无效。") }
                    requiresSource = true
                }
                var extents: [PayloadExtent] = []
                for extent in try op.messages(6) {
                    let start = try checkedMultiply(extent.number(1), block)
                    let count = try checkedMultiply(extent.number(2), block)
                    let upper = try checkedAdd(start, count)
                    guard count > 0, upper <= 1 << 40 else { throw InputError.invalid("Payload 目标区间大小无效。") }
                    extents.append(PayloadExtent(start: start, size: count)); ranges.append(start..<upper); end = max(end, upper)
                }
                guard !extents.isEmpty else { throw InputError.invalid("Payload 操作没有目标区间。") }
                let hash = op.bytes(8)
                if let hash, hash.count != 32 { throw InputError.invalid("操作 SHA-256 长度无效。") }
                operations.append(PayloadOperation(type: type, offset: offset, length: length, extents: extents, hash: hash))
            }
            let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
            for index in 1..<max(1, sorted.count) where sorted[index].lowerBound < sorted[index - 1].upperBound {
                throw InputError.invalid("分区 \(name) 的目标写入区间重叠。")
            }
            let declaredSize = info?.number(1) ?? 0
            guard declaredSize == 0 || (declaredSize >= end && declaredSize <= 1 << 40) else { throw InputError.invalid("分区大小与目标区间不一致。") }
            partitions.append(PayloadPartition(name: name, size: max(end, declaredSize), operationCount: operations.count,
                unsupportedTypes: Array(Set(operations.map(\.type).filter { ![0, 1, 6, 7, 8, 14].contains($0) })).sorted(),
                requiresSource:requiresSource, operations: operations, expectedHash: partitionHash))
        }
        return PayloadLayout(partitions:partitions.sorted { $0.name < $1.name },blockSize:block,dataOffset:dataOffset)
    }

    public func cleanup() { if isTemporary { try? FileManager.default.removeItem(at: sourceURL) } }

    public func extract(names: Set<String>, to directory: URL, control: WorkControl = WorkControl(),
                        progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> [URL] {
        let selected = partitions.filter { names.contains($0.name) }
        guard !selected.isEmpty, selected.count == names.count else { throw InputError.invalid("请选择有效的分区。") }
        guard selected.allSatisfy(\.extractable) else { throw InputError.invalid("所选分区含增量或尚未支持的压缩操作，请使用全量 OTA。") }
        try snapshot.validate()
        try control.check()
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let total = try selected.reduce(UInt64(0)) { try checkedAdd($0, $1.size) }
        var completed: UInt64 = 0, files: [URL] = []
        for partition in selected {
            let writer = try PayloadImageWriter(partition:partition,blockSize:blockSize,directory:directory)
            var written: UInt64 = 0
            for operation in partition.operations {
                try control.check()
                guard operation.length <= 256*1024*1024 else { throw InputError.invalid("单个 Payload 操作超过当前 256 MiB 内存上限。") }
                let encoded = try input.readExactly(offset:checkedAdd(dataOffset,operation.offset),count:Int(operation.length),fileSize:fileSize)
                written = try checkedAdd(written,writer.apply(operation,encoded:encoded,control:control))
                progress(WorkProgress("提取 \(partition.name)",done:min(total,completed+written),total:total))
            }
            progress(WorkProgress("校验 \(partition.name) SHA-256",done:completed+partition.size,total:total))
            try writer.verify(control:control); try snapshot.validate()
            files.append(try writer.commit(control:control)); completed += partition.size
            progress(WorkProgress("已完成 \(partition.name)",done:completed,total:total))
        }
        return files
    }
}
