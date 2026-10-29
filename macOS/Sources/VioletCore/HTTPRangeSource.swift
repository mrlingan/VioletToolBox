import Foundation

public protocol FirmwareByteSource: Sendable {
    var size: UInt64 { get }
    func read(offset: UInt64, count: Int, control: WorkControl) async throws -> Data
}

public struct LocalByteSource: FirmwareByteSource {
    public let size: UInt64
    private let snapshot: FileSnapshot
    public init(_ url: URL) throws { snapshot = try FileSnapshot(url); size = snapshot.size }
    public func read(offset: UInt64, count: Int, control: WorkControl) async throws -> Data {
        try control.check(); try snapshot.validate()
        guard count >= 0, count <= 64 * 1024 * 1024 else { throw InputError.invalid("本地随机读取超过单次限制。") }
        let handle = try FileHandle(forReadingFrom:snapshot.url); defer { try? handle.close() }
        let data = try handle.readExactly(offset:offset,count:count,fileSize:size)
        try snapshot.validate(); try control.check(); return data
    }
}

public struct HTTPRangeSource: FirmwareByteSource {
    public let url: URL
    public let size: UInt64
    public let etag: String?
    public let lastModified: String?
    public var hasValidator: Bool { strongETag != nil || lastModified != nil }
    private var strongETag: String? { etag.flatMap { $0.hasPrefix("W/") ? nil : $0 } }
    private let headers: [String:String]

    public static func open(_ url: URL, headers: [String:String] = [:], control: WorkControl = WorkControl()) async throws -> HTTPRangeSource {
        _ = try HTTPClient.httpURL(url.absoluteString)
        try validateHeaders(headers)
        let response = try await fetch(url:url,headers:headers,start:0,count:1,expected:nil,control:control)
        return HTTPRangeSource(url:url,size:response.size,etag:response.etag,lastModified:response.modified,headers:headers)
    }
    public func read(offset: UInt64, count: Int, control: WorkControl) async throws -> Data {
        try control.check()
        guard count >= 0, count <= 64 * 1024 * 1024, offset <= size, UInt64(count) <= size-offset else { throw InputError.invalid("远程读取范围越界或超过 64 MiB。") }
        if count == 0 { return Data() }
        var result = Data(), done = 0
        result.reserveCapacity(count)
        while done < count {
            let chunk = min(4 * 1024 * 1024,count-done)
            let response = try await Self.fetch(url:url,headers:headers,start:offset+UInt64(done),count:chunk,expected:self,control:control)
            result.append(response.data); done += response.data.count
        }
        try control.check(); return result
    }
    private static func validateHeaders(_ headers: [String:String]) throws {
        guard headers.count <= 64 else { throw InputError.invalid("远程请求头过多。") }
        let reserved = ["range","if-range","if-match","accept-encoding","content-length","host"]
        for (key,value) in headers {
            guard !key.isEmpty, key.utf8.count <= 128, value.utf8.count <= 16*1024,
                  key.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![40,41,60,62,64,44,59,58,92,34,47,91,93,63,61,123,125].contains($0) }),
                  !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains), !reserved.contains(key.lowercased()) else { throw InputError.invalid("远程请求头无效，或尝试覆盖范围 / 文件标识。") }
        }
    }
    private static func fetch(url: URL, headers: [String:String], start: UInt64, count: Int, expected: HTTPRangeSource?, control: WorkControl) async throws -> RangeResult {
        guard count > 0, count <= 4 * 1024 * 1024 else { throw InputError.invalid("单次 HTTP Range 大小无效。") }
        let end = try checkedAdd(start,UInt64(count)-1)
        for attempt in 0..<3 {
            try control.check(); try Task.checkCancellation()
            var request = URLRequest(url:url)
            for (key,value) in headers { request.setValue(value,forHTTPHeaderField:key) }
            request.setValue("bytes=\(start)-\(end)",forHTTPHeaderField:"Range")
            request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
            if let validator = expected?.strongETag ?? expected?.lastModified { request.setValue(validator,forHTTPHeaderField:"If-Range") }
            let sink = RangeSink(start:start,end:end,count:count,expected:expected,control:control)
            let stream = HTTPStream(request:request,onResponse:{ try sink.response($0) },onData:{ try sink.receive($0) },redirect:{ response,newRequest in
                guard let target = newRequest.url, ["http","https"].contains(target.scheme?.lowercased() ?? ""), target.user == nil, target.password == nil,
                      !(response.url?.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https") else { return nil }
                var next = newRequest
                let old = response.url
                if old?.host?.lowercased() != target.host?.lowercased() || old?.port != target.port || old?.scheme != target.scheme {
                    for key in headers.keys where !["user-agent","referer","accept"].contains(key.lowercased()) { next.setValue(nil,forHTTPHeaderField:key) }
                    next.setValue(nil,forHTTPHeaderField:"Authorization"); next.setValue(nil,forHTTPHeaderField:"Cookie")
                }
                next.setValue("bytes=\(start)-\(end)",forHTTPHeaderField:"Range"); next.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
                return next
            })
            do { try await stream.run(); return try sink.finish() }
            catch {
                try control.check(); try Task.checkCancellation()
                let retry = error as? RangeRetry
                let network = error as? URLError
                guard attempt < 2, retry != nil || network.map({ [.timedOut,.networkConnectionLost,.cannotConnectToHost,.notConnectedToInternet].contains($0.code) }) == true else { throw error }
                try await Task.sleep(nanoseconds:UInt64(min(30,retry?.delay ?? (0.45 * Double(attempt+1))) * 1_000_000_000))
            }
        }
        throw InputError.invalid("HTTP Range 重试结束。")
    }
}

private struct RangeRetry: LocalizedError {
    let status: Int
    let delay: Double
    var errorDescription: String? { "远程服务器返回 HTTP \(status)，请稍后重试。" }
}
private struct RangeResult { let data: Data; let size: UInt64; let etag: String?; let modified: String? }
private final class RangeSink {
    let start: UInt64, end: UInt64
    let count: Int
    let expected: HTTPRangeSource?
    let control: WorkControl
    var data = Data(), size: UInt64 = 0
    var etag: String?, modified: String?
    init(start: UInt64, end: UInt64, count: Int, expected: HTTPRangeSource?, control: WorkControl) {
        self.start = start; self.end = end; self.count = count; self.expected = expected; self.control = control
    }
    func response(_ response: HTTPURLResponse) throws {
        try control.check()
        if [429,502,503,504].contains(response.statusCode) { throw RangeRetry(status:response.statusCode,delay:min(30,max(0.45,Double(response.value(forHTTPHeaderField:"Retry-After") ?? "") ?? 0.9))) }
        guard response.statusCode == 206 else { throw InputError.invalid("远程未返回 206 Range 响应（HTTP \(response.statusCode)），没有退回整包下载。") }
        guard (response.value(forHTTPHeaderField:"Content-Encoding") ?? "identity").lowercased() == "identity" else { throw InputError.invalid("Range 响应启用了传输压缩。") }
        guard let raw = response.value(forHTTPHeaderField:"Content-Range"), raw.range(of:"^bytes [0-9]+-[0-9]+/[0-9]+$",options:.regularExpression) != nil else { throw InputError.invalid("缺少有效 Content-Range。") }
        let parts = raw.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { UInt64($0) }
        guard parts.count == 3, parts[0] == start, parts[1] == end, parts[2] > end, parts[2] <= UInt64(Int64.max),
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(count) else { throw InputError.invalid("服务器响应范围或长度与请求不符。") }
        size = parts[2]; etag = response.value(forHTTPHeaderField:"ETag"); modified = response.value(forHTTPHeaderField:"Last-Modified")
        if let expected {
            guard size == expected.size else { throw InputError.invalid("远程文件大小已变化，请重新打开。") }
            if let old = expected.etag, !old.hasPrefix("W/") {
                guard etag == old else { throw InputError.invalid("远程 ETag 已变化，请重新打开。") }
            } else if let old = expected.lastModified {
                guard modified == old else { throw InputError.invalid("远程修改时间已变化，请重新打开。") }
            } else if let old = expected.etag {
                guard etag == old else { throw InputError.invalid("远程弱 ETag 已变化，请重新打开。") }
            }
        }
    }
    func receive(_ bytes: Data) throws {
        try control.check()
        guard bytes.count <= count-data.count else { throw InputError.invalid("Range 响应超过请求长度。") }
        data.append(bytes)
    }
    func finish() throws -> RangeResult {
        try control.check()
        guard size > 0, data.count == count else { throw InputError.invalid("Range 响应已截断，未使用不完整数据。") }
        return RangeResult(data:data,size:size,etag:etag,modified:modified)
    }
}
