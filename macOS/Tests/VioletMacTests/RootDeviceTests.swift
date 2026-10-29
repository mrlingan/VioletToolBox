import XCTest
import VioletCore
@testable import VioletMac

@MainActor final class RootDeviceTests: XCTestCase {
    private func fixture() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("violet-root-mock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let adb = """
        #!/bin/sh
        root="$(dirname "$0")"
        if [ "$1" = devices ]; then printf 'one device\\ntwo device\\n'; exit 0; fi
        if [ "$4" = getprop ]; then printf '[ro.product.model]: [Mock]\\n'; exit 0; fi
        printf '%s|' "$@" | tr '\\n' ' ' >> "$root/calls"; printf '\\n' >> "$root/calls"
        case "$*" in
          *VIOLET_ROOT_V1*) printf 'VIOLET_ROOT_V1\\nMagisk\\t/sbin/magisk\\tdGVzdA==\\n';;
          *VIOLET_MODULES_V1*) printf 'VIOLET_MODULES_V1\\n';;
          *) printf 'Success\\n';;
        esac
        """
        for (name, text) in [("adb",adb),("fastboot","#!/bin/sh\nexit 0\n")] {
            let url = root.appendingPathComponent(name); try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: url.path)
        }
        let model = AppModel(); model.customDirectory = root.path
        return (model, root)
    }
    private func idle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("operation did not finish"); await model.shutdown()
    }
    func testRootInstallRequiresReviewAndKeepsCapturedDevice() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh(); model.selectedID = "adb:one"; model.selectionChanged()
        model.detectRootManagers(); try await idle(model)
        XCTAssertTrue(model.rootReady)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VioletCoreTests/Fixtures")
        model.modulePackages = [try ModulePackage.open(fixtures.appendingPathComponent("TEST_ONLY_module_one.zip"))]
        model.installRootModules()
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.detail.contains("序列号：one")); XCTAssertTrue(pending.detail.contains("SHA-256"))
        var calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertFalse(calls.contains("--install-module"))
        model.selectedID = "adb:two"; model.selectionChanged()
        XCTAssertFalse(model.rootReady)
        pending.action(); try await idle(model)
        calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("--install-module"))
        XCTAssertTrue(calls.components(separatedBy: .newlines).filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("-s|one|") })
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
    }
    func testBatchAppReviewAndSerialBinding() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh(); model.selectedID = "adb:one"; model.selectionChanged()
        model.batchAppCommand(["org.test.two","org.test.one"], prefix: ["shell","pm","clear"], title: "清除测试数据", warning: "fixture")
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.detail.contains("org.test.one")); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
        model.selectedID = "adb:two"; model.selectionChanged(); pending.action(); try await idle(model)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("-s|one|shell|pm|clear|org.test.one|")); XCTAssertTrue(calls.contains("-s|one|shell|pm|clear|org.test.two|"))
        XCTAssertFalse(calls.contains("-s|two|"))
    }
    func testInvalidPackageNeverCreatesDeviceCommand() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh(); model.selectedID = "adb:one"
        model.batchAppCommand(["org.ok","bad;reboot"], prefix: ["uninstall"], title: "fixture")
        XCTAssertNotNil(model.error); XCTAssertFalse(model.busy); XCTAssertNil(model.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
    }
}
