import Foundation

public struct DownloadMetadata: Codable, Sendable {
    public var sourceURL: String
    public var etag: String?
    public var lastModified: String?
    public var totalBytes: UInt64?
    public var completed: Bool
    var validator: String? { etag ?? lastModified }
}

private final class DownloadSink {
    let part: URL
    let metadataURL: URL
    let offset: UInt64
    let previous: DownloadMetadata?
    let source: URL
    let progress: @Sendable (WorkProgress) -> Void
    var metadata: DownloadMetadata?
    var output: FileHandle?
    var received: UInt64 = 0
    var alreadyComplete = false
    var discardedErrorBytes = 0
    var lastReport = Date.distantPast
    init(part: URL, metadataURL: URL, offset: UInt64, previous: DownloadMetadata?, source: URL,
         progress: @escaping @Sendable (WorkProgress) -> Void) {
        self.part = part; self.metadataURL = metadataURL; self.offset = offset; self.previous = previous; self.source = source; self.progress = progress
    }
    func response(_ response: HTTPURLResponse) throws {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
        guard encoding == "identity" else { throw InputError.invalid("服务器启用了传输压缩，无法安全续传。") }
        let code = response.statusCode
        let rawETag = response.value(forHTTPHeaderField: "ETag")
        let etag = rawETag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let modified = response.value(forHTTPHeaderField: "Last-Modified")
        if code == 416, offset > 0, let previous, previous.totalBytes == offset,
           response.value(forHTTPHeaderField: "Content-Range") == "bytes */\(offset)",
           previous.etag != nil ? previous.etag == etag : previous.lastModified != nil && previous.lastModified == modified {
            metadata = DownloadMetadata(sourceURL: source.absoluteString, etag: etag, lastModified: modified, totalBytes: offset, completed: true)
            alreadyComplete = true
            return
        }
        guard code == 200 || code == 206 else { throw InputError.invalid("下载服务器返回 HTTP \(code)。已下载部分已保留。") }
        guard offset == 0 || code == 206 else { throw InputError.invalid("服务器拒绝续传或文件已更新。已保留旧片段，请选择新目标重新下载。") }
        var total: UInt64?
        if code == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  let match = range.range(of: "^bytes [0-9]+-[0-9]+/[0-9]+$", options: .regularExpression), match == range.startIndex..<range.endIndex else {
                throw InputError.invalid("服务器未返回有效的 Content-Range。")
            }
            let parts = range.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { UInt64($0) }
            guard parts.count == 3, parts[0] == offset, parts[1] >= parts[0], parts[2] > parts[1], parts[1] == parts[2] - 1 else {
                throw InputError.invalid("服务器返回的续传范围与请求不一致。")
            }
            total = parts[2]
            if response.expectedContentLength >= 0, UInt64(response.expectedContentLength) != parts[1] - parts[0] + 1 {
                throw InputError.invalid("Content-Length 与续传范围不一致。")
            }
        } else if response.expectedContentLength >= 0 { total = UInt64(response.expectedContentLength) }
        if offset > 0, let previous {
            guard previous.totalBytes == nil || total == previous.totalBytes else { throw InputError.invalid("文件大小已变化，不能拼接到旧片段。") }
            if let expected = previous.etag {
                guard etag == expected else { throw InputError.invalid("文件 ETag 已变化，不能拼接到旧片段。") }
            } else {
                guard let expected = previous.lastModified, expected == modified else { throw InputError.invalid("文件修改时间已变化，不能拼接到旧片段。") }
            }
        }
        metadata = DownloadMetadata(sourceURL: source.absoluteString, etag: etag, lastModified: modified, totalBytes: total, completed: false)
        if offset == 0 {
            if !FileManager.default.fileExists(atPath: part.path) {
                guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw InputError.invalid("无法创建下载文件。") }
            } else {
                let current = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.uint64Value
                guard previous != nil, current == 0 else { throw InputError.invalid("下载片段已存在，未覆盖。") }
            }
        }
        output = try FileHandle(forWritingTo: part)
        guard try output?.seekToEnd() == offset else { throw InputError.invalid("下载片段大小已被其他程序修改。") }
        try saveMetadata()
    }
    func saveMetadata() throws {
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }
    func receive(_ data: Data) throws {
        if alreadyComplete {
            guard data.count <= 65536 - discardedErrorBytes else { throw InputError.invalid("服务器错误响应过大。") }
            discardedErrorBytes += data.count; return
        }
        guard let output, let metadata else { throw InputError.invalid("下载响应尚未验证。") }
        let newCount = try checkedAdd(checkedAdd(offset, received), UInt64(data.count))
        if let total = metadata.totalBytes, newCount > total { throw InputError.invalid("服务器发送的数据超过声明长度。") }
        try output.write(contentsOf: data)
        received += UInt64(data.count)
        if Date().timeIntervalSince(lastReport) >= 0.15 {
            progress(WorkProgress("正在下载", done: offset + received, total: metadata.totalBytes ?? 0)); lastReport = Date()
        }
    }
    func finish() throws -> DownloadMetadata {
        guard var metadata else { throw InputError.invalid("下载未收到有效响应。") }
        try output?.synchronize(); try output?.close(); output = nil
        let size = offset + received
        if let total = metadata.totalBytes, total != size { throw InputError.invalid("下载长度不完整，已保留片段以供续传。") }
        metadata.totalBytes = size; metadata.completed = true; self.metadata = metadata
        try saveMetadata()
        progress(WorkProgress("下载完成", done: size, total: size))
        return metadata
    }
    deinit { try? output?.close() }
}

public actor ResumableDownload {
    private var active: HTTPStream?
    public init() {}
    public func cancel() { active?.cancel() }
    public static func partialURL(for destination: URL) -> URL { destination.appendingPathExtension("violet-part") }
    public static func metadataURL(for destination: URL) -> URL { destination.appendingPathExtension("violet-part.json") }

    public func download(from source: URL, to destination: URL, headers: [String: String] = [:], control: WorkControl = WorkControl(),
                         progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) async throws -> URL {
        try control.check()
        guard active == nil else { throw InputError.invalid("已有下载正在运行。") }
        _ = try HTTPClient.httpURL(source.absoluteString)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw InputError.invalid("目标文件已存在，未覆盖。请选择其他文件名。") }
        let part = Self.partialURL(for: destination), metadataURL = Self.metadataURL(for: destination)
        let offset = ((try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        var metadata: DownloadMetadata?
        if FileManager.default.fileExists(atPath: part.path) {
            guard let data = try? Data(contentsOf: metadataURL), let previous = try? JSONDecoder().decode(DownloadMetadata.self, from: data) else {
                throw InputError.invalid("下载片段缺少有效的续传记录，请选择新目标。")
            }
            metadata = previous
            if previous.completed, previous.totalBytes == offset {
                try FileManager.default.moveItem(at: part, to: destination); try? FileManager.default.removeItem(at: metadataURL); return destination
            }
            guard offset == 0 || previous.validator != nil else { throw InputError.invalid("服务器未提供可用的 ETag / 修改时间，无法校验续传。请选择新文件名重新下载。") }
        }
        var request = URLRequest(url: source)
        for (key, value) in headers {
            guard !key.contains(where: { $0.isNewline }), !value.contains(where: { $0.isNewline }) else { throw InputError.invalid("下载请求头无效。") }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(metadata?.validator, forHTTPHeaderField: "If-Range")
        }
        let sink = DownloadSink(part: part, metadataURL: metadataURL, offset: offset, previous: metadata, source: source, progress: progress)
        let stream = HTTPStream(request: request, onResponse: { try control.check(); try sink.response($0) }, onData: { try control.check(); try sink.receive($0) })
        active = stream
        defer { active = nil }
        try await stream.run()
        _ = try sink.finish()
        try FileManager.default.moveItem(at: part, to: destination)
        try? FileManager.default.removeItem(at: metadataURL)
        return destination
    }
}
