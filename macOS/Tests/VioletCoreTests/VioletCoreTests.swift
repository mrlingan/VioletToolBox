import XCTest
@testable import VioletCore

final class DeviceTests: XCTestCase {
    func testMixedADBStatesAndDaemonNoise() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        usb123 device product:foo model:Pixel_9 device:tokay transport_id:1
        wifi:37123 unauthorized transport_id:2
        offline123 offline
        recovery123 recovery
        ota123 sideload
        """
        let devices = Device.parseADB(output)
        XCTAssertEqual(devices.count, 5)
        XCTAssertEqual(devices[0].label, "Pixel 9")
        XCTAssertTrue(devices[0].shellReady)
        XCTAssertFalse(devices[1].ready)
        XCTAssertFalse(devices[2].ready)
        XCTAssertTrue(devices[3].shellReady)
        XCTAssertTrue(devices[4].ready)
        XCTAssertFalse(devices[4].shellReady)
    }

    func testFastbootAndADBHaveDistinctIDs() {
        let adb = Device.parseADB("same device")[0]
        let fastboot = Device.parseFastboot("same\tfastboot\n< waiting for any device >")[0]
        XCTAssertNotEqual(adb.id, fastboot.id)
        XCTAssertTrue(fastboot.ready)
        XCTAssertFalse(fastboot.shellReady)
    }

    func testPropertiesPreserveEmbeddedBracketsAndEmptyValues() {
        let values = Device.properties("[ro.product.model]: [Pixel]\n[empty]: []\n[x]: [a]: [b]\ninvalid")
        XCTAssertEqual(values["ro.product.model"], "Pixel")
        XCTAssertEqual(values["empty"], "")
        XCTAssertEqual(values["x"], "a]: [b")
        XCTAssertEqual(values.count, 3)
    }
}

final class InputTests: XCTestCase {
    func testPathsAndQuotesInCommandArguments() throws {
        XCTAssertEqual(try Input.arguments("flash boot '/Users/安/My boot.img'"), ["flash", "boot", "/Users/安/My boot.img"])
        XCTAssertEqual(try Input.arguments("shell echo \"\" a\\ b"), ["shell", "echo", "", "a b"])
        XCTAssertThrowsError(try Input.arguments("flash 'unfinished"))
        XCTAssertThrowsError(try Input.arguments("abc\\"))
    }

    func testValidatePartitionAndEndpoint() throws {
        XCTAssertEqual(try Input.partition("init_boot_a"), "init_boot_a")
        for value in ["", "--slot", "boot;reboot", "boot a", "../boot"] { XCTAssertThrowsError(try Input.partition(value)) }
        XCTAssertEqual(try Input.endpoint("192.168.1.4:37123"), "192.168.1.4:37123")
        XCTAssertEqual(try Input.endpoint("[::1]:5555"), "[::1]:5555")
        for value in ["-evil:55", "192.168.1.2", "host:0", "host:65536", "host:55;id"] { XCTAssertThrowsError(try Input.endpoint(value)) }
    }

    func testConsoleCannotOverrideSelectedDevice() throws {
        for line in ["-s other reboot", "-sother reboot", "reboot --serial=other", "reboot -sother"] {
            XCTAssertThrowsError(try Input.deviceArguments(line, tool: "fastboot"))
        }
        XCTAssertThrowsError(try Input.deviceArguments("kill-server", tool: "adb"))
        XCTAssertThrowsError(try Input.deviceArguments("adb reboot", tool: "adb"))
        XCTAssertEqual(try Input.deviceArguments("shell ls -l /sdcard", tool: "adb"), ["shell", "ls", "-l", "/sdcard"])
    }

    func testRemotePathCannotInjectAShellCommand() async throws {
        let hostile = "/sdcard/a'; echo injected; # with spaces $HOME"
        let result = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s' " + Input.remoteQuote(hostile)])
        XCTAssertEqual(result.stdout, hostile)
        XCTAssertTrue(result.succeeded)
    }
}

final class CommandRunnerTests: XCTestCase {
    func testLargeSimultaneousOutputDoesNotDeadlock() async throws {
        let result = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 12000 ]; do echo output; echo error >&2; i=$((i+1)); done"], timeout: 15)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.components(separatedBy: "\n").count, 12001)
        XCTAssertEqual(result.stderr.components(separatedBy: "\n").count, 12001)
    }

    func testStdinBinaryAndNonzeroExit() async throws {
        let runner = CommandRunner()
        let data = Data([0, 255, 10, 137, 80, 78, 71])
        let copy = try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: data)
        XCTAssertEqual(copy.data, data)
        let fail = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo reason >&2; exit 9"])
        XCTAssertEqual(fail.status, 9)
        XCTAssertFalse(fail.succeeded)
        XCTAssertTrue(fail.stderr.contains("reason"))
    }

    func testTimeoutKillsCLIAndRunnerCanBeReused() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        let next = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["ready"])
        XCTAssertTrue(next.succeeded)
    }

    func testCancellationStopsChildAndRejectsConcurrentWork() async throws {
        let runner = CommandRunner()
        let job = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["unexpected"])
            XCTFail("Concurrent commands must be rejected")
        } catch { }
        await runner.cancel()
        let result = try await job.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.succeeded)
    }

    func testFailedLaunchDoesNotLeaveRunnerBusy() async throws {
        let runner = CommandRunner()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [])
            XCTFail("Expected launch error")
        } catch { }
        let next = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["ready"])
        XCTAssertTrue(next.succeeded)
    }

    func testCallerTaskCancellationAlsoStopsChild() async throws {
        let runner = CommandRunner()
        let job = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        job.cancel()
        let result = try await job.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.succeeded)
    }
}
