import XCTest
@testable import VioletCore

final class CommandStreamTests: XCTestCase {
    func testBinaryCaptureSkipsUTF8ConversionAndKeepsDiagnostics() async throws {
        let result = try await CommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c","import os,sys;os.write(1,bytes([255,0,254]));sys.stderr.write('diagnostic')"], captureText: false)
        XCTAssertEqual(result.data, Data([255,0,254])); XCTAssertTrue(result.stdout.isEmpty); XCTAssertEqual(result.stderr, "diagnostic")
    }
    func testStreamingBinaryOutputHasExactBytesAndNoTextConversion() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("image.bin"), runner = CommandRunner()
        let script = "import os,sys\nfor i in range(128): os.write(1,bytes(range(256))*256)\nsys.stderr.write('fixture diagnostic')"
        let result = try await runner.stream(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c",script], to: output, expectedSize: 8 * 1024 * 1024)
        XCTAssertEqual(result.size, 8 * 1024 * 1024); XCTAssertEqual(result.stderr, "fixture diagnostic")
        let handle = try FileHandle(forReadingFrom: output); defer { try? handle.close() }
        XCTAssertEqual(try handle.readExactly(offset: 7 * 1024 * 1024, count: 256, fileSize: result.size), Data(0...255))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }
    func testShortOutputFailureAndTimeoutRemovePartialFiles() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        for (index, script) in ["import os;os.write(1,b'short')", "import os,sys;os.write(1,b'fail');sys.exit(9)", "import time;print('slow');time.sleep(10)"].enumerated() {
            let output = root.appendingPathComponent("\(index).bin")
            do { _ = try await runner.stream(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c",script], to: output, expectedSize: 1024, timeout: 0.3); XCTFail("must reject") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testCancellationStopsStreamingAndExistingFileNeverChanges() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("cancel.bin"), runner = CommandRunner()
        let started = expectation(description: "stream produced output"), gate = WorkControl()
        let task = Task {
            try await runner.stream(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c","import os,time\nfor i in range(100):\n os.write(1,b'x'*65536);time.sleep(.03)"], to: output, expectedSize: 6553600) { progress in
                if progress.done > 0, !gate.isCancelled { gate.cancel(); started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 3); task.cancel()
        do { _ = try await task.value; XCTFail("cancel") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try Data("keep".utf8).write(to: output)
        do { _ = try await runner.stream(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["overwrite"], to: output, expectedSize: 10); XCTFail("overwrite") } catch { }
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
    }
    func testOversizedProducerIsStopped() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("too-long.bin"), runner = CommandRunner()
        let start = Date()
        do {
            _ = try await runner.stream(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c","import os,time\nfor i in range(100):\n os.write(1,b'x'*4096);time.sleep(.01)\ntime.sleep(20)"], to: output, expectedSize: 8192, timeout: 3)
            XCTFail("too long")
        } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
