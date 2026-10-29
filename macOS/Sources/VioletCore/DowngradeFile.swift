import Foundation
import CryptoKit

public struct DowngradeFile: Sendable {
    public let source: URL
    public let size: UInt64
    private let snapshot: FileSnapshot
    private let expectedMD5: String?
    public static func package(_ source: URL, matching package: DowngradePackage) throws -> DowngradeFile {
        try package.validateForInstall()
        let snapshot = try FileSnapshot(source)
        guard snapshot.size == package.fileSize else { throw InputError.invalid("降级包大小不符：预期 \(package.fileSize)，实际 \(snapshot.size) bytes。") }
        return DowngradeFile(source: source, size: snapshot.size, snapshot: snapshot, expectedMD5: package.md5)
    }
    public static func apk(_ source: URL) throws -> DowngradeFile {
        let snapshot = try FileSnapshot(source)
        guard snapshot.size >= 4, snapshot.size <= 512 * 1024 * 1024 else { throw InputError.invalid("APK 为空或超过 512 MiB。") }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard try input.readExactly(offset:0,count:4,fileSize:snapshot.size) == Data([0x50,0x4b,3,4]) else { throw InputError.invalid("所选 APK 不含 ZIP 文件头。") }
        try snapshot.validate()
        return DowngradeFile(source:source,size:snapshot.size,snapshot:snapshot,expectedMD5:nil)
    }
    public func validate() throws { try snapshot.validate() }
    public func verify(control: WorkControl, progress: @Sendable (WorkProgress) -> Void = { _ in }) throws {
        try process(output:nil,control:control,progress:progress)
    }
    public func stage(to destination: URL, control: WorkControl, progress: @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        let output = try AtomicOutput(destination)
        try process(output:output,control:control,progress:progress)
        return try output.commit()
    }
    private func process(output: AtomicOutput?, control: WorkControl, progress: @Sendable (WorkProgress) -> Void) throws {
        try control.check(); try snapshot.validate()
        let input = try FileHandle(forReadingFrom:source); defer { try? input.close() }
        var hash = Insecure.MD5(), done: UInt64 = 0
        while done < size {
            try control.check()
            let bytes = try input.readExactly(offset:done,count:Int(min(4*1024*1024,size-done)),fileSize:size)
            if expectedMD5 != nil { hash.update(data:bytes) }
            try output?.handle.write(contentsOf:bytes)
            done += UInt64(bytes.count)
            progress(WorkProgress(expectedMD5 == nil ? "复制降级助手 APK" : "降级包大小 / MD5 校验",done:done,total:size))
        }
        try snapshot.validate(); try control.check()
        if let expectedMD5 {
            let actual = hash.finalize().map { String(format:"%02x",$0) }.joined()
            guard actual == expectedMD5 else { throw InputError.invalid("降级包 MD5 不匹配，未执行后续推送 / 安装。") }
        }
    }
}
