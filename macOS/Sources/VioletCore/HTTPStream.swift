import Foundation

// Validates headers before accepting the body, and streams data without buffering
// a multi-gigabyte ROM in memory. URLSession serializes delegate callbacks.
final class HTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let onResponse: (HTTPURLResponse) throws -> Void
    private let onData: (Data) throws -> Void
    private let redirect: ((HTTPURLResponse, URLRequest) -> URLRequest?)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var cancelled = false

    init(request: URLRequest, onResponse: @escaping (HTTPURLResponse) throws -> Void, onData: @escaping (Data) throws -> Void,
         redirect: ((HTTPURLResponse, URLRequest) -> URLRequest?)? = nil) {
        self.request = request; self.onResponse = onResponse; self.onData = onData; self.redirect = redirect
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 7 * 24 * 3600
                config.httpMaximumConnectionsPerHost = 2
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.session = session; self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    private func record(_ error: Error) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let redirect { completionHandler(redirect(response, request)) }
        else { completionHandler(request) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw InputError.invalid("不是有效的 HTTP 响应。") }
            try onResponse(response); completionHandler(.allow)
        } catch { record(error); completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try onData(data) } catch { record(error); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil; self.task = nil; self.session = nil
        let failure = self.failure ?? (cancelled ? CancellationError() : error)
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }
}

private final class HTTPBuffer {
    var data = Data()
}

public enum HTTPClient {
    public static func httpURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw InputError.invalid("请输入有效的 HTTP / HTTPS 地址。") }
        return url
    }
    public static func data(for request: URLRequest, limit: Int = 4 * 1024 * 1024) async throws -> Data {
        let buffer = HTTPBuffer()
        let stream = HTTPStream(request: request, onResponse: { response in
            guard (200..<300).contains(response.statusCode) else { throw InputError.invalid("服务器返回 HTTP \(response.statusCode)。") }
            guard response.expectedContentLength < 0 || response.expectedContentLength <= limit else { throw InputError.invalid("服务器响应过大。") }
        }, onData: { data in
            guard data.count <= limit - buffer.data.count else { throw InputError.invalid("服务器响应超过大小上限。") }
            buffer.data.append(data)
        })
        try await stream.run()
        return buffer.data
    }
}
