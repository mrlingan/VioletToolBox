import XCTest
import VioletCore
@testable import VioletMac

final class AppModelTests: XCTestCase {
    @MainActor func testOperationCanStartWhileDeviceDiscoveryIsRefreshing() async {
        let model = AppModel()
        model.refreshing = true
        let ran = expectation(description: "Local work runs while discovery is refreshing")
        model.perform("本地文件任务") { ran.fulfill() }
        await fulfillment(of: [ran], timeout: 2)
        XCTAssertFalse(model.busy)
    }
    @MainActor func fixture(_ listing: String) throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("violet-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try listing.write(to: root.appendingPathComponent("devices.txt"), atomically: true, encoding: .utf8)
        let adb = """
        #!/bin/sh
        root="$(dirname "$0")"
        if [ "$1" = devices ]; then cat "$root/devices.txt"; exit 0; fi
        if [ "$1" = -s ] && [ "$3" = shell ] && [ "$4" = getprop ]; then
            printf '[ro.product.model]: [Fixture Phone]\\n'
            exit 0
        fi
        printf '%s\\n' "$@"
        """
        for (name, content) in [("adb", adb), ("fastboot", "#!/bin/sh\nexit 0\n")] {
            let path = root.appendingPathComponent(name)
            try content.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let model = AppModel()
        model.customDirectory = root.path
        return (model, root)
    }

    @MainActor func testMultipleDevicesRequireSelectionAndDisconnectDoesNotRetarget() async throws {
        let (model, root) = try fixture("one device model:Phone_One\ntwo device model:Phone_Two\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh()
        XCTAssertEqual(model.devices.count, 2)
        XCTAssertNil(model.selected)
        model.selectedID = "adb:one"
        model.selectionChanged()
        await model.refresh(force: true)
        XCTAssertEqual(model.properties["ro.product.model"], "Fixture Phone")
        try "two device model:Phone_Two\n".write(to: root.appendingPathComponent("devices.txt"), atomically: true, encoding: .utf8)
        await model.refresh()
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.selectedID, "adb:one")
        XCTAssertTrue(model.properties.isEmpty)
        XCTAssertFalse(model.adbReady)
    }

    @MainActor func testExecutionBindsCapturedSerialAndRejectsWrongTransport() async throws {
        let (model, root) = try fixture("one device\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh()
        let device = try XCTUnwrap(model.selected)
        let result = try await model.execute("adb", ["shell", "echo", "中文 path"], device: device)
        XCTAssertEqual(result.stdout, "-s\none\nshell\necho\n中文 path\n")
        do {
            _ = try await model.execute("fastboot", ["reboot"], device: device)
            XCTFail("Wrong transport must not execute")
        } catch { }
    }

    @MainActor func testDestructiveCommandOnlyPreparesReviewableConfirmation() async throws {
        let (model, root) = try fixture("one device\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh()
        model.command("清除数据", args: ["shell", "pm", "clear", "org.example.app"], destructive: true, detail: "测试确认")
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.detail.contains("序列号：one"))
        XCTAssertTrue(pending.detail.contains("pm clear org.example.app"))
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.log.contains("$ adb"))
    }

    @MainActor func testCancelPreventsNextBatchStep() async throws {
        let (model, root) = try fixture("one device\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh()
        model.cancel()
        do {
            _ = try await model.execute("adb", ["shell", "echo", "next-step"])
            XCTFail("Cancellation must stop later batch steps")
        } catch { }
        XCTAssertFalse(model.log.contains("next-step"))
    }
}
