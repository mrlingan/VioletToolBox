import XCTest
import VioletCore
@testable import VioletMac

@MainActor final class FlashPlanDeviceTests: XCTestCase {
    private func fixture() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("violet-flash-mock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let text = #"""
        #!/bin/sh
        root="$(dirname "$0")"
        if [ "$1" = devices ]; then printf 'one fastboot\ntwo fastboot\n'; exit 0; fi
        printf '%s|' "$@" >> "$root/calls"; printf '\n' >> "$root/calls"
        case "$3:$4" in
          getvar:product) value=TEST_ONLY; [ ! -f "$root/product" ] || value=$(cat "$root/product"); echo "product: $value" >&2;;
          getvar:anti) echo 'anti: 5' >&2;;
          getvar:current-slot) echo 'current-slot: a' >&2;;
          getvar:has-slot:*) echo "$4: yes" >&2;;
          getvar:partition-size:*) value=0x1000; [ ! -f "$root/capacity" ] || value=$(cat "$root/capacity"); echo "$4: $value" >&2;;
          flash:*) [ ! -f "$root/fail" ] || { echo 'FAILED TEST_ONLY' >&2; exit 0; }; echo OKAY >&2;;
          *) echo OKAY >&2;;
        esac
        """#
        for (name, script) in [("fastboot",text),("adb","#!/bin/sh\nexit 0\n")] {
            let file = root.appendingPathComponent(name); try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: file.path)
        }
        try Data(count: 512).write(to: root.appendingPathComponent("boot.img"))
        let model = AppModel(); model.customDirectory = root.path
        model.flashPlan = try FlashPlan.create(root: root, product: "TEST_ONLY", maximumAnti: 5, steps: [FlashStep(.flash, target: "boot", image: "boot.img"),FlashStep(.setActive, target: "b"),FlashStep(.flash, target: "boot", image: "boot.img"),FlashStep(.reboot)])
        return (model,root)
    }
    private func idle(_ model: AppModel) async throws {
        for _ in 0..<500 { if !model.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("operation did not finish"); await model.shutdown()
    }
    private func review(_ model: AppModel) async throws -> PendingOperation {
        await model.refresh(); model.selectedID = "fastboot:one"; model.reviewFlashPlan(); try await idle(model)
        return try XCTUnwrap(model.pending)
    }
    func testReviewDoesNotWriteAndExecutionResolvesSlotsAndKeepsCapturedSerial() async throws {
        let (model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pending = try await review(model)
        XCTAssertTrue(pending.detail.contains("boot_a")); XCTAssertTrue(pending.detail.contains("boot_b")); XCTAssertTrue(pending.detail.contains("序列号：one"))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("calls")).contains("|flash|"))
        model.selectedID = "fastboot:two"; model.selectionChanged(); pending.action(); try await idle(model)
        XCTAssertNil(model.error)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("-s|one|flash|boot_a|")); XCTAssertTrue(calls.contains("-s|one|flash|boot_b|")); XCTAssertFalse(calls.contains("-s|two|"))
        let writes = calls.components(separatedBy: .newlines).filter { $0.contains("|flash|") || $0.contains("|set_active|") || $0.contains("|reboot|") }
        XCTAssertEqual(writes.count, 4); XCTAssertTrue(writes[1].contains("|set_active|b|"))
    }
    func testChangedLaterInputStopsBeforeFirstWrite() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let later = root.appendingPathComponent("later.img"); try Data(count: 512).write(to: later)
        model.flashPlan = try FlashPlan.create(root: root, steps: [FlashStep(.flash, target: "boot_a", image: "boot.img"),FlashStep(.flash, target: "boot_b", image: "later.img")])
        let pending = try await review(model); try Data([1]).write(to: later); pending.action(); try await idle(model)
        XCTAssertNotNil(model.error); XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("calls")).contains("|flash|"))
    }
    func testProductAndCapacityChangesAfterReviewStopBeforeWrites() async throws {
        for change in [("product","OTHER"),("capacity","0x2000")] {
            let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let pending = try await review(model); try change.1.write(to: root.appendingPathComponent(change.0), atomically: true, encoding: .utf8)
            pending.action(); try await idle(model)
            XCTAssertNotNil(model.error); XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("calls")).contains("|flash|"))
        }
    }
    func testVendorFailureAtZeroExitStopsFollowingSteps() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pending = try await review(model); try Data().write(to: root.appendingPathComponent("fail")); pending.action(); try await idle(model)
        XCTAssertNotNil(model.error)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("|flash|")); XCTAssertFalse(calls.contains("|set_active|")); XCTAssertFalse(calls.contains("|reboot|"))
    }
    func testUnsupportedScriptNeverReachesDeviceQueries() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.flashPlan = try FlashPlan.parse("if errorlevel 1 goto end\nfastboot flash boot boot.img", root: root, windows: true)
        await model.refresh(); model.selectedID = "fastboot:one"; model.reviewFlashPlan(); try await idle(model)
        XCTAssertNil(model.pending); XCTAssertNotNil(model.error); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
    }
}
