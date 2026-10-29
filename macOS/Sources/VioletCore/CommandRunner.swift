import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let data: Data
    public let timedOut: Bool
    public let cancelled: Bool
    public var succeeded: Bool { status == 0 && !timedOut && !cancelled }
    public var text: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

public struct CommandFileResult: Sendable {
    public let url: URL
    public let size: UInt64
    public let stderr: String
}

public actor CommandRunner {
    private var process: Process?
    private var didCancel = false
    public init() {}

    public func cancel() {
        didCancel = true
        if let process, process.isRunning { stop(process) }
    }

    public func cancelAndWait() async {
        cancel()
        while process != nil { await pause() }
    }

    private func pause() async {
        // This wait must also yield when the caller's Task has been cancelled.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.08) { continuation.resume() }
        }
    }

    private func stop(_ child: Process) {
        child.terminate()
        // Some CLI tools ignore SIGTERM. Always reap the process before re-enabling UI.
        Task.detached { [weak child] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    public func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 60, input: Data? = nil, workingDirectory: URL? = nil, captureText: Bool = true,
                    stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await runProcess(executable: executable, arguments: arguments, environment: environment, timeout: timeout, input: input, workingDirectory: workingDirectory, captureText: captureText, stderrLine: stderrLine)
    }

    public func stream(executable: URL, arguments: [String], to destination: URL, expectedSize: UInt64,
                       environment: [String: String]? = nil, timeout: TimeInterval = 3600,
                       progress: @Sendable (WorkProgress) -> Void = { _ in }) async throws -> CommandFileResult {
        guard expectedSize > 0, expectedSize <= UInt64(Int64.max) else { throw InputError.invalid("流式输出的声明大小无效。") }
        try Task.checkCancellation()
        let output = try AtomicOutput(destination)
        let result = try await runProcess(executable: executable, arguments: arguments, environment: environment, timeout: timeout,
            stream: output.handle, limit: expectedSize, progress: progress)
        try Task.checkCancellation()
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw InputError.invalid("数据回读超时，半成品已清理。") }
        guard result.succeeded else { throw InputError.invalid("数据回读失败（\(result.status)）：\(result.stderr.suffix(3000))") }
        let size = try output.handle.seekToEnd()
        guard size == expectedSize else { throw InputError.invalid("回读长度不匹配：期望 \(expectedSize)，实际 \(size) bytes。") }
        progress(WorkProgress(destination.lastPathComponent, done: size, total: expectedSize))
        return CommandFileResult(url: try output.commit(), size: size, stderr: result.stderr)
    }

    private func runProcess(executable: URL, arguments: [String], environment: [String: String]?,
                            timeout: TimeInterval, input: Data? = nil, workingDirectory: URL? = nil,
                            stream: FileHandle? = nil, limit: UInt64? = nil,
                            captureText: Bool = true,
                            stderrLine: (@Sendable (String) -> Void)? = nil,
                            progress: @Sendable (WorkProgress) -> Void = { _ in }) async throws -> CommandResult {
        guard process == nil else { throw InputError.invalid("已有命令正在执行。") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("violet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = folder.appendingPathComponent("stdout"), errURL = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let events: FileHandle?
        if stderrLine == nil { events = nil }
        else { events = try FileHandle(forReadingFrom: errURL) }
        defer { try? events?.close() }
        var pendingLines = Data()
        func emitLines() {
            guard let events, let stderrLine else { return }
            for _ in 0..<4 {
                guard let bytes = try? events.read(upToCount: 65536), !bytes.isEmpty else { break }
                pendingLines.append(bytes)
                while let end = pendingLines.firstIndex(of: 10) {
                    stderrLine(String(decoding: pendingLines[..<end], as: UTF8.self)); pendingLines.removeSubrange(...end)
                }
                if pendingLines.count > 65536 { pendingLines = Data(pendingLines.suffix(65536)) }
            }
        }
        let child = Process()
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        child.currentDirectoryURL = workingDirectory
        child.standardOutput = stream ?? out; child.standardError = err
        if let input {
            let inputURL = folder.appendingPathComponent("stdin")
            try input.write(to: inputURL)
            child.standardInput = try FileHandle(forReadingFrom: inputURL)
        } else { child.standardInput = FileHandle.nullDevice }
        didCancel = false
        process = child
        defer { process = nil }
        let start = Date()
        try child.run()
        var timedOut = false
        var limitExceeded = false
        while child.isRunning {
            emitLines()
            if Task.isCancelled, !didCancel { didCancel = true; stop(child) }
            if !timedOut, Date().timeIntervalSince(start) > timeout {
                timedOut = true; stop(child)
            }
            if let stream, let limit {
                let size = (try? stream.offset()) ?? 0
                progress(WorkProgress("接收数据", done: size, total: limit))
                if size > limit, !limitExceeded { limitExceeded = true; stop(child) }
            }
            await pause()
        }
        emitLines()
        let data = stream == nil ? try Data(contentsOf: outURL) : Data()
        return CommandResult(status: child.terminationStatus, stdout: captureText ? String(decoding: data, as: UTF8.self) : "",
                             stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self),
                             data: data, timedOut: timedOut, cancelled: didCancel)
    }
}
