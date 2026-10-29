import XCTest
@testable import VioletCore

final class FlashPlanTests: XCTestCase {
    func testWindowsParsingPreservesOrderPathsOptionsAndProductGuard() throws {
        let text = #"""
        @echo off
        chcp 65001>nul
        fastboot %* getvar product 2>&1 | findstr /r /c:"^product: *salami" || exit /b 1
        fastboot %* flash boot_a "%~dp0images\boot.img" || exit /b 1
        fastboot --disable-verity --disable-verification flash vbmeta_a "images\vbmeta.img"
        fastboot erase userdata
        fastboot set_active b
        fastboot reboot
        """#
        let plan = try FlashPlan.parse(text, root: URL(fileURLWithPath: "/tmp/TEST_ONLY"), windows: true)
        XCTAssertTrue(plan.canExecute, plan.issues.joined(separator: "\n")); XCTAssertEqual(plan.document.product, "salami")
        XCTAssertEqual(plan.document.steps.map(\.operation), [.flash,.flash,.erase,.setActive,.reboot])
        XCTAssertEqual(plan.document.steps[0].image, "images/boot.img")
        XCTAssertEqual(plan.document.steps[1].options, ["--disable-verity","--disable-verification"])
    }
    func testUnsupportedControlFlowAntiBlocksAndTargetOverridesCannotExecute() throws {
        for unsupported in ["if errorlevel 1 goto end", "set CURRENT_ANTI_VER=5", "fastboot -s other erase userdata", "fastboot flash boot boot.img & fastboot erase userdata", "echo ok & fastboot erase userdata", "exit /b 0", "fastboot --slot=all flash boot boot.img", "fastboot oem unlock"] {
            let plan = try FlashPlan.parse(unsupported + "\nfastboot flash boot_a boot.img", root: URL(fileURLWithPath: "/tmp"), windows: true)
            XCTAssertFalse(plan.canExecute, unsupported); XCTAssertFalse(plan.issues.isEmpty); XCTAssertThrowsError(try plan.validate())
        }
    }
    func testSimpleShellQuotingAndInvalidStructure() throws {
        let plan = try FlashPlan.parse("#!/bin/sh\nset -eu\nfastboot flash boot_a 'images/boot image.img' || exit $?\nfastboot reboot", root: URL(fileURLWithPath: "/tmp"), windows: false)
        XCTAssertTrue(plan.canExecute); XCTAssertEqual(plan.document.steps[0].image, "images/boot image.img")
        XCTAssertThrowsError(try FlashPlan.parse("fastboot reboot fastboot\nfastboot flash boot boot.img", root: URL(fileURLWithPath: "/tmp"), windows: false))
        XCTAssertThrowsError(try FlashPlan.create(root: URL(fileURLWithPath: "/tmp"), steps: [FlashStep(.flash, target: "boot", image: "../outside.img")]))
        XCTAssertThrowsError(try FlashPlan.create(root: URL(fileURLWithPath: "/tmp"), steps: [FlashStep(.flash, target: "-s", image: "boot.img")]))
    }
    func testJSONRoundtripAndSourceChangesBlockExecution() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try FlashPlan.create(root: root, product: "test", maximumAnti: 9, steps: [FlashStep(.erase, target: "userdata")])
        let file = try plan.exportJSON(to: root.appendingPathComponent("plan.json")), imported = try FlashPlan.open(file)
        XCTAssertEqual(imported.document.steps, plan.document.steps); XCTAssertEqual(imported.document.maximumAnti, 9)
        XCTAssertThrowsError(try plan.exportJSON(to: file))
        try Data([1]).write(to: file); XCTAssertThrowsError(try imported.validate())
    }
    func testScanExcludesSensitiveSlotVariantsAndSymlinkEscape() throws {
        let root = try PayloadFixture.directory(), outside = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        for name in ["boot.img","boot_b.img","persist_a.img","ocdt.bin","modemst1_b.img","other.txt"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        let plan = try FlashPlan.scan(root)
        XCTAssertEqual(plan.document.steps.map(\.target), ["boot","boot_b"])
        try Data([2]).write(to: outside.appendingPathComponent("image.img"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.img"), withDestinationURL: outside.appendingPathComponent("image.img"))
        XCTAssertThrowsError(try plan.imageURL("escape.img")); XCTAssertThrowsError(try plan.imageURL("../image.img"))
    }
    func testRequirementsAndVariableResponsesRejectMissingConflictsAndAntiRollback() throws {
        let plan = try FlashPlan.create(root: URL(fileURLWithPath: "/tmp"), product: "salami", maximumAnti: 5, steps: [FlashStep(.erase, target: "userdata")])
        try plan.checkRequirements(product: "salami", anti: "5")
        XCTAssertThrowsError(try plan.checkRequirements(product: "other", anti: "5"))
        for anti in [nil,"6","unknown","-1","4294967296"] { XCTAssertThrowsError(try plan.checkRequirements(product: "salami", anti: anti)) }
        XCTAssertEqual(try FlashPlan.variable("partition-size:boot", from: "(bootloader) partition-size:boot: 0x1000\nFinished. Total time: 0s"), "0x1000")
        XCTAssertThrowsError(try FlashPlan.variable("product", from: "product: one\nproduct: two"))
        XCTAssertThrowsError(try FlashPlan.variable("product", from: "FAILED unknown variable"))
    }
    func testGeneratedShellValidatesAllInputsBeforeWritingAndBindsSerial() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = "boot 'quoted' 中文.img"; try Data(repeating: 65, count: 512).write(to: root.appendingPathComponent(image))
        let plan = try FlashPlan.create(root: root, product: "TEST_ONLY", maximumAnti: 9, steps: [FlashStep(.flash, target: "boot", image: image),FlashStep(.erase, target: "userdata"),FlashStep(.reboot)])
        let script = try plan.exportShell(to: root.appendingPathComponent("flash.command")), tool = try mockTool(root)
        var env = ProcessInfo.processInfo.environment; env["VIOLET_FASTBOOT"] = tool.path
        let syntax = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-n",script.path])
        XCTAssertTrue(syntax.succeeded, syntax.text)
        let declined = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path,"SIMULATED_ONLY"], environment: env)
        XCTAssertFalse(declined.succeeded); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
        let result = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path,"SIMULATED_ONLY","--execute"], environment: env)
        XCTAssertTrue(result.succeeded, result.text)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("-s|SIMULATED_ONLY|flash|boot_a|")); XCTAssertTrue(calls.contains("|erase|userdata|")); XCTAssertTrue(calls.contains("|reboot|"))
        XCTAssertTrue(calls.components(separatedBy: .newlines).filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("-s|SIMULATED_ONLY|") })
        try FileManager.default.removeItem(at: root.appendingPathComponent("calls"))
        try Data([2]).write(to: root.appendingPathComponent(image))
        let tampered = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path,"SIMULATED_ONLY","--execute"], environment: env)
        XCTAssertFalse(tampered.succeeded); XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("calls")).contains("|flash|"))
    }
    func testGeneratedShellCapacityAndVendorZeroExitFailureStopNextCommands() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 8192).write(to: root.appendingPathComponent("boot.img"))
        let plan = try FlashPlan.create(root: root, steps: [FlashStep(.flash, target: "boot", image: "boot.img"),FlashStep(.erase, target: "userdata")])
        let script = try plan.exportShell(to: root.appendingPathComponent("flash.command")), tool = try mockTool(root)
        var env = ProcessInfo.processInfo.environment; env["VIOLET_FASTBOOT"] = tool.path
        let small = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path,"SIMULATED_ONLY","--execute"], environment: env)
        XCTAssertFalse(small.succeeded); XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("calls")).contains("|flash|"))
        try "0x4000".write(to: root.appendingPathComponent("capacity"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("fail")); try FileManager.default.removeItem(at: root.appendingPathComponent("calls"))
        let failed = try await CommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path,"SIMULATED_ONLY","--execute"], environment: env)
        XCTAssertFalse(failed.succeeded); let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("|flash|")); XCTAssertFalse(calls.contains("|erase|"))
    }
    private func mockTool(_ root: URL) throws -> URL {
        let tool = root.appendingPathComponent("fastboot")
        let text = #"""
        #!/bin/sh
        root="$(dirname "$0")"
        printf '%s|' "$@" >> "$root/calls"; printf '\n' >> "$root/calls"
        case "$3:$4" in
          getvar:product) echo 'product: TEST_ONLY' >&2;;
          getvar:anti) echo 'anti: 5' >&2;;
          getvar:current-slot) echo 'current-slot: a' >&2;;
          getvar:has-slot:boot) echo 'has-slot:boot: yes' >&2;;
          getvar:has-slot:*) echo "$4: no" >&2;;
          getvar:partition-size:*) size=0x1000; [ ! -f "$root/capacity" ] || size=$(cat "$root/capacity"); echo "$4: $size" >&2;;
          flash:*) [ ! -f "$root/fail" ] || { echo 'FAILED (TEST_ONLY simulated failure)' >&2; exit 0; }; echo OKAY >&2;;
          *) echo OKAY >&2;;
        esac
        """#
        try text.write(to: tool, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: tool.path)
        return tool
    }
}
