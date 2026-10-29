import Foundation
import CryptoKit
import VioletNative

struct PayloadMetadataHeader: Sendable {
    let manifestSize: UInt64
    let dataOffset: UInt64
    init(_ header: Data, fileSize: UInt64) throws {
        guard header.count == 24, header.prefix(4) == Data("CrAU".utf8), try header.integer(at:4,bytes:8,bigEndian:true) == 2 else { throw InputError.invalid("不是受支持的 Payload v2 文件。") }
        manifestSize = try header.integer(at:12,bytes:8,bigEndian:true)
        guard manifestSize > 0, manifestSize <= 64*1024*1024 else { throw InputError.invalid("Payload manifest 大小异常。") }
        dataOffset = try checkedAdd(checkedAdd(24,manifestSize),header.integer(at:20,bytes:4,bigEndian:true))
        guard dataOffset <= fileSize else { throw InputError.invalid("Payload 元数据或签名区域已截断。") }
    }
}
struct PayloadLayout: Sendable {
    let partitions: [PayloadPartition]
    let blockSize: UInt64
    let dataOffset: UInt64
}

final class PayloadImageWriter {
    private let output: AtomicOutput
    private let partition: PayloadPartition
    private let blockSize: UInt64
    init(partition: PayloadPartition, blockSize: UInt64, directory: URL) throws {
        guard partition.extractable else { throw InputError.invalid("分区包含需旧镜像的差分操作或未支持的压缩。") }
        self.partition = partition; self.blockSize = blockSize
        output = try AtomicOutput(directory.appendingPathComponent(partition.name + ".img"))
        try output.handle.truncate(atOffset:partition.size)
    }
    func apply(_ operation: PayloadOperation, encoded: Data, control: WorkControl) throws -> UInt64 {
        try control.check()
        guard UInt64(encoded.count) == operation.length else { throw InputError.invalid("Payload 操作读取不完整。") }
        if let hash = operation.hash, Data(SHA256.hash(data:encoded)) != hash { throw InputError.invalid("\(partition.name) 操作 SHA-256 校验失败。") }
        let capacity = try operation.extents.reduce(UInt64(0)) { try checkedAdd($0,$1.size) }
        if operation.type == 6 || operation.type == 7 { return capacity }
        guard operation.length > 0, operation.length <= 256*1024*1024, capacity <= 256*1024*1024 else { throw InputError.invalid("单个 Payload 操作超过当前 256 MiB 内存上限。") }
        var decoded: Data
        if operation.type == 0 { decoded = encoded }
        else {
            decoded = Data(count:Int(capacity)); var written = 0
            let status = decoded.withUnsafeMutableBytes { output in encoded.withUnsafeBytes { input in
                violet_decompress(Int32(operation.type),input.bindMemory(to:UInt8.self).baseAddress,input.count,output.bindMemory(to:UInt8.self).baseAddress,output.count,&written)
            } }
            guard status == 0 else { throw InputError.invalid("\(partition.name) 解压失败（\(status)）。") }
            decoded.count = written
        }
        guard UInt64(decoded.count) <= capacity, capacity-UInt64(decoded.count) < blockSize else { throw InputError.invalid("\(partition.name) 解压长度与目标区间不一致。") }
        if UInt64(decoded.count) < capacity { decoded.append(Data(count:Int(capacity)-decoded.count)) }
        var offset = 0
        for extent in operation.extents {
            try control.check(); try output.handle.seek(toOffset:extent.start)
            try output.handle.write(contentsOf:decoded.subdata(in:offset..<offset+Int(extent.size))); offset += Int(extent.size)
        }
        return capacity
    }
    func verify(control: WorkControl) throws {
        try control.check(); try output.handle.synchronize()
        if let expected = partition.expectedHash {
            try output.handle.seek(toOffset:0)
            var hash = SHA256(), read: UInt64 = 0
            while read < partition.size {
                try control.check()
                let data = try output.handle.read(upToCount:Int(min(1024*1024,partition.size-read))) ?? Data()
                guard !data.isEmpty else { throw InputError.invalid("输出镜像已截断。") }
                hash.update(data:data); read += UInt64(data.count)
            }
            guard Data(hash.finalize()) == expected else { throw InputError.invalid("\(partition.name) 镜像 SHA-256 校验失败。") }
        }
    }
    func commit(control: WorkControl) throws -> URL { try control.check(); return try output.commit() }
}
