import Foundation

public final class WorkControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw CancellationError() } }
}

public struct WorkProgress: Sendable {
    public let label: String
    public let done: UInt64
    public let total: UInt64
    public init(_ label: String, done: UInt64, total: UInt64) { self.label = label; self.done = done; self.total = total }
    public var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
}

extension Data {
    func integer(at offset: Int, bytes: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard offset >= 0, bytes > 0, bytes <= 8, offset <= count, bytes <= count - offset else { throw InputError.invalid("文件头不完整。") }
        var value: UInt64 = 0
        for index in 0..<bytes {
            let shift = bigEndian ? (bytes - index - 1) * 8 : index * 8
            value |= UInt64(self[startIndex + offset + index]) << shift
        }
        return value
    }
}

func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw InputError.invalid("文件偏移超出支持范围。") }
    return value
}

func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw InputError.invalid("分区大小超出支持范围。") }
    return value
}

extension FileHandle {
    func readExactly(offset: UInt64, count: Int, fileSize: UInt64) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { throw InputError.invalid("文件已截断或数据范围无效。") }
        try seek(toOffset: offset)
        let data = try read(upToCount: count) ?? Data()
        guard data.count == count else { throw InputError.invalid("文件读取不完整。") }
        return data
    }
}
