import XCTest
@testable import VioletCore

final class FixtureServer {
    let process = Process()
    let root: URL
    var base: URL!
    private var stopped = false
    init() throws { root = try PayloadFixture.directory() }
    func start() async throws {
        let port = root.appendingPathComponent("port")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/http_server.py").path, port.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let value = try? String(contentsOf: port), let number = Int(value) {
                base = URL(string: "http://127.0.0.1:\(number)")!; return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw InputError.invalid("无法启动本地测试服务器。")
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        // waitUntilExit can strand a Swift concurrency worker in a CFRunLoop,
        // even after the Python child exits. Foundation reaps the child itself.
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    deinit { stop() }
    static var body: Data { Data((0..<4096).flatMap { _ in (0...255).map(UInt8.init) }) }
    func seedPartial(_ destination: URL, validator: Bool = true) throws -> Data {
        let prefix = Self.body.prefix(8192)
        try prefix.write(to: ResumableDownload.partialURL(for: destination))
        let metadata = DownloadMetadata(sourceURL: base.appendingPathComponent("old").absoluteString, etag: validator ? "\"fixture-v1\"" : nil,
                                        lastModified: nil, totalBytes: UInt64(Self.body.count), completed: false)
        try JSONEncoder().encode(metadata).write(to: ResumableDownload.metadataURL(for: destination))
        return prefix
    }
}

final class HTTPTests: XCTestCase {
    func testROMQueriesUnicodeAndCarriesDownloadHeaders() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        let client = ROMClient(baseURL: server.base.appendingPathComponent("rom"))
        var selection = ROMSelection()
        let series = try await client.list("series", selection: selection)
        XCTAssertEqual(series, ["系列 A", "系列 B"])
        selection.series = series[0]
        let devices = try await client.list("devices", selection: selection)
        XCTAssertEqual(devices, ["测试机型"])
        selection.device = devices[0]
        let versions = try await client.list("versions", selection: selection)
        XCTAssertEqual(versions, ["测试版本"])
        selection.version = versions[0]
        let links = try await client.links(selection: selection)
        XCTAssertEqual(links.items.count, 2)
        XCTAssertEqual(links.items[0].label, "主地址")
        XCTAssertEqual(links.headers["Referer"], "https://example.invalid/firmware")
        let destination = server.root.appendingPathComponent("rom.zip")
        _ = try await ResumableDownload().download(from: links.items[0].url, to: destination, headers: links.headers)
        XCTAssertEqual(try Data(contentsOf: destination), FixtureServer.body)
    }

    func testFullDownloadAndReplacementLinkResumeAreByteExact() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        let download = ResumableDownload()
        let first = server.root.appendingPathComponent("full.zip")
        _ = try await download.download(from: server.base.appendingPathComponent("file"), to: first)
        XCTAssertEqual(try Data(contentsOf: first), FixtureServer.body)
        let resumed = server.root.appendingPathComponent("resume.zip")
        _ = try server.seedPartial(resumed)
        _ = try await download.download(from: server.base.appendingPathComponent("file").appending(queryItems: [.init(name: "new", value: "signature")]), to: resumed)
        XCTAssertEqual(try Data(contentsOf: resumed), FixtureServer.body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ResumableDownload.partialURL(for: resumed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ResumableDownload.metadataURL(for: resumed).path))
    }

    func testChangedFileIgnoredRangeAndWrongRangePreservePartial() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        for path in ["changed", "ignore", "wrong"] {
            let destination = server.root.appendingPathComponent(path + ".zip")
            let original = try server.seedPartial(destination)
            do {
                _ = try await ResumableDownload().download(from: server.base.appendingPathComponent(path), to: destination)
                XCTFail("Invalid resume must fail: \(path)")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: ResumableDownload.partialURL(for: destination)), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testPauseThenResumeAndTaskCancellation() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        let destination = server.root.appendingPathComponent("paused.zip")
        let service = ResumableDownload(), token = WorkControl()
        do {
            _ = try await service.download(from: server.base.appendingPathComponent("slow"), to: destination, control: token) { progress in
                if progress.done > 32768 { token.cancel(); Task { await service.cancel() } }
            }
            XCTFail("Expected cancellation")
        } catch { }
        let size = try FileManager.default.attributesOfItem(atPath: ResumableDownload.partialURL(for: destination).path)[.size] as! NSNumber
        XCTAssertGreaterThan(size.intValue, 0)
        XCTAssertLessThan(size.intValue, FixtureServer.body.count)
        _ = try await service.download(from: server.base.appendingPathComponent("file"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), FixtureServer.body)
        let request = URLRequest(url: server.base.appendingPathComponent("slow"))
        let job = Task { try await HTTPClient.data(for: request) }
        try await Task.sleep(nanoseconds: 100_000_000); job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancelled HTTP task") } catch { }
    }

    func testTruncatedResponseCanResumeWithoutDuplicatingBytes() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        let destination = server.root.appendingPathComponent("truncated.zip"), service = ResumableDownload()
        do {
            _ = try await service.download(from: server.base.appendingPathComponent("short"), to: destination)
            XCTFail("Truncated response must not become final file")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        _ = try await service.download(from: server.base.appendingPathComponent("file"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), FixtureServer.body)
    }

    func testErrorsOversizedJSONAndNoValidatorCannotOverwriteData() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        do { _ = try await HTTPClient.data(for: URLRequest(url: server.base.appendingPathComponent("oversize"))); XCTFail("Expected size limit") } catch { }
        let destination = server.root.appendingPathComponent("forbidden.zip")
        do { _ = try await ResumableDownload().download(from: server.base.appendingPathComponent("error"), to: destination); XCTFail("Expected HTTP error") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ResumableDownload.partialURL(for: destination).path))
        let original = try server.seedPartial(destination, validator: false)
        do { _ = try await ResumableDownload().download(from: server.base.appendingPathComponent("file"), to: destination); XCTFail("Expected identity error") } catch { }
        XCTAssertEqual(try Data(contentsOf: ResumableDownload.partialURL(for: destination)), original)
        let existing = server.root.appendingPathComponent("existing.zip")
        try original.write(to: existing)
        do { _ = try await ResumableDownload().download(from: server.base.appendingPathComponent("file"), to: existing); XCTFail("Expected existing file error") } catch { }
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    func testZeroBytePartialCanRestartAndCompletePartialCanFinalize() async throws {
        let server = try FixtureServer(); try await server.start(); defer { server.stop() }
        for complete in [false, true] {
            let destination = server.root.appendingPathComponent("edge-\(complete).zip")
            _ = try server.seedPartial(destination)
            try (complete ? FixtureServer.body : Data()).write(to: ResumableDownload.partialURL(for: destination))
            _ = try await ResumableDownload().download(from: server.base.appendingPathComponent("file"), to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), FixtureServer.body)
        }
    }
}
