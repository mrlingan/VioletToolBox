import Foundation
import CryptoKit

public struct FirmwareVersionDetails: Sendable {
    public let bytes: Data
    public let text: String
    public let fields: [String:String]
    public var productName: String { value("product_name","pre-device") }
    public var model: String { WindowsDeviceNames.values[productName.uppercased()] ?? "" }
    public var androidVersion: String { value("android_version") }
    public var versionName: String { value("version_name","post-build-incremental","post-build") }
    public var securityPatch: String { value("security_patch","post-security-patch-level") }
    public var summary: String {
        [model.isEmpty ? nil : "手机机型：\(model)", "设备代号：\(productName.isEmpty ? "--" : productName)", "安卓版本：\(androidVersion.isEmpty ? "--" : androidVersion)", "版本信息：\(versionName.isEmpty ? "--" : versionName)", "安全补丁：\(securityPatch.isEmpty ? "--" : securityPatch)"].compactMap { $0 }.joined(separator:"\n")
    }
    public init(_ data: Data) throws {
        guard data.count <= 4*1024*1024, let text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) else { throw InputError.invalid("OTA metadata 过大或编码无效。") }
        self.text = text
        bytes = data
        var fields: [String:String] = [:]
        for line in text.components(separatedBy:.newlines) {
            guard let index = line.firstIndex(of:"=") else { continue }
            let key = line[..<index].trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            fields[key] = line[line.index(after:index)...].trimmingCharacters(in:.whitespacesAndNewlines)
        }
        self.fields = fields
    }
    private func value(_ keys: String...) -> String { keys.compactMap { fields[$0] }.first { !$0.isEmpty } ?? "" }
    public static func readRemote(_ url: URL, headers: [String:String] = [:], control: WorkControl = WorkControl()) async throws -> FirmwareVersionDetails {
        let source = try await HTTPRangeSource.open(url,headers:RemoteFirmwareArchive.preparedHeaders(url,headers:headers),control:control)
        let archive = try await RangeZIPArchive.open(source,control:control)
        guard let entry = archive.entry(named:"META-INF/com/android/metadata") else { throw InputError.invalid("OTA ZIP 中没有 META-INF/com/android/metadata。") }
        let bytes = try await archive.contents(of:entry,control:control)
        try await archive.validate(control:control)
        return try FirmwareVersionDetails(bytes)
    }
    public static func readLocal(_ url: URL, control: WorkControl = WorkControl()) async throws -> FirmwareVersionDetails {
        let archive = try await RangeZIPArchive.open(LocalByteSource(url),control:control)
        guard let entry = archive.entry(named:"META-INF/com/android/metadata") else { throw InputError.invalid("OTA ZIP 中没有 META-INF/com/android/metadata。") }
        let data = try await archive.contents(of:entry,control:control)
        return try FirmwareVersionDetails(data)
    }
}

public struct RemotePayloadArchive: Sendable {
    public let partitions: [PayloadPartition]
    public let blockSize: UInt64
    public let fileSize: UInt64
    private let source: any FirmwareByteSource
    private let dataOffset: UInt64
    private let header: Data
    private let manifestSize: Int
    private let manifestHash: Data

    public static func open(_ source: any FirmwareByteSource, control: WorkControl = WorkControl()) async throws -> RemotePayloadArchive {
        let header = try await source.read(offset:0,count:24,control:control)
        let metadata = try PayloadMetadataHeader(header,fileSize:source.size)
        let manifest = try await source.read(offset:24,count:Int(metadata.manifestSize),control:control)
        let layout = try PayloadArchive.parseManifest(header:header,manifestBytes:manifest,fileSize:source.size,control:control)
        return RemotePayloadArchive(partitions:layout.partitions,blockSize:layout.blockSize,fileSize:source.size,source:source,dataOffset:layout.dataOffset,header:header,manifestSize:manifest.count,manifestHash:Data(SHA256.hash(data:manifest)))
    }
    public func validate(control: WorkControl) async throws {
        let current = try await source.read(offset:0,count:24,control:control)
        guard current == header else { throw InputError.invalid("远程 Payload 文件头已变化。") }
        let manifest = try await source.read(offset:24,count:manifestSize,control:control)
        guard Data(SHA256.hash(data:manifest)) == manifestHash else { throw InputError.invalid("远程 Payload manifest 已变化，请重新打开。") }
    }
    public func extract(names: Set<String>, to directory: URL, control: WorkControl = WorkControl(), progress: @escaping @Sendable (WorkProgress)->Void = { _ in }) async throws -> [URL] {
        let selected = partitions.filter { names.contains($0.name) }
        guard !selected.isEmpty, selected.count == names.count, selected.allSatisfy(\.extractable) else { throw InputError.invalid("请选择可直接提取的完整分区；源镜像差分和未知压缩不能直接导出。") }
        try await validate(control:control)
        let total = try selected.reduce(UInt64(0)) { try checkedAdd($0,$1.size) }
        var completed: UInt64 = 0, files: [URL] = []
        for partition in selected {
            let writer = try PayloadImageWriter(partition:partition,blockSize:blockSize,directory:directory)
            var written: UInt64 = 0
            for operation in partition.operations {
                try control.check()
                guard operation.length <= 256*1024*1024 else { throw InputError.invalid("单个 Payload 操作超过当前 256 MiB 内存上限。") }
                var encoded = Data(), position: UInt64 = 0
                encoded.reserveCapacity(Int(operation.length))
                while position < operation.length {
                    let count = Int(min(4*1024*1024,operation.length-position))
                    let bytes = try await source.read(offset:checkedAdd(checkedAdd(dataOffset,operation.offset),position),count:count,control:control)
                    encoded.append(bytes); position += UInt64(bytes.count)
                    progress(WorkProgress("读取 \(partition.name) 操作数据",done:position,total:operation.length))
                }
                written = try checkedAdd(written,writer.apply(operation,encoded:encoded,control:control))
                progress(WorkProgress("提取 \(partition.name)",done:min(total,completed+written),total:total))
            }
            progress(WorkProgress("校验 \(partition.name) SHA-256",done:completed+partition.size,total:total))
            try writer.verify(control:control)
            try await validate(control:control)
            files.append(try writer.commit(control:control)); completed += partition.size
            progress(WorkProgress("已完成 \(partition.name)",done:completed,total:total))
        }
        return files
    }
}

public struct RemoteFirmwareArchive: Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let size: UInt64
    public let hasValidator: Bool
    public let payload: RemotePayloadArchive?
    public let zip: RangeZIPArchive?
    public let version: FirmwareVersionDetails?
    public let diagnostics: [String]
    public static func open(_ url: URL, headers: [String:String] = [:], control: WorkControl = WorkControl()) async throws -> RemoteFirmwareArchive {
        let source = try await HTTPRangeSource.open(url,headers:preparedHeaders(url,headers:headers),control:control)
        let signature = try await source.read(offset:0,count:Int(min(4,source.size)),control:control)
        if signature == Data("CrAU".utf8) {
            let payload = try await RemotePayloadArchive.open(source,control:control)
            return RemoteFirmwareArchive(id:UUID(),url:url,size:source.size,hasValidator:source.hasValidator,payload:payload,zip:nil,version:nil,diagnostics:[])
        }
        guard signature.prefix(2) == Data([0x50,0x4b]) else { throw InputError.invalid("远程输入不是 ZIP 或 Payload；网页链接请先取得实际下载地址。") }
        let zip = try await RangeZIPArchive.open(source,control:control)
        var version: FirmwareVersionDetails?, payload: RemotePayloadArchive?, diagnostics: [String] = []
        if let metadata = zip.entry(named:"META-INF/com/android/metadata") {
            do { let bytes = try await zip.contents(of:metadata,control:control); version = try FirmwareVersionDetails(bytes) }
            catch { try control.check(); try Task.checkCancellation(); diagnostics.append("metadata：" + error.localizedDescription) }
        }
        if let entry = try zip.payloadEntry() {
            do { let reader = try await zip.storedSource(for:entry,control:control); payload = try await RemotePayloadArchive.open(reader,control:control) }
            catch { try control.check(); try Task.checkCancellation(); diagnostics.append("Payload：" + error.localizedDescription) }
        }
        try await zip.validate(control:control)
        return RemoteFirmwareArchive(id:UUID(),url:url,size:source.size,hasValidator:source.hasValidator,payload:payload,zip:zip,version:version,diagnostics:diagnostics)
    }
    static func preparedHeaders(_ url: URL, headers: [String:String]) -> [String:String] {
        var result = headers
        let host = url.host?.lowercased() ?? ""
        if host == "firmware-res.flyme.com" || ((host == "flyme.com" || host.hasSuffix(".flyme.com")) && url.path == "/zh/download") {
            if !headers.keys.contains(where: { $0.lowercased() == "referer" }) { result["Referer"] = "https://www.flyme.com/firmware.html" }
            if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { result["User-Agent"] = "Mozilla/5.0 (Macintosh) VioletToolBox" }
        }
        return result
    }
}
