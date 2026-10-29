import XCTest
import VioletCore
@testable import VioletMac

@MainActor final class PartitionDeviceTests: XCTestCase {
    private func fixture() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("violet-partition-mock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = """
        #!/bin/sh
        root="$(dirname "$0")"
        if [ "$1" = devices ]; then printf 'one device\\ntwo device\\n'; exit 0; fi
        if [ "$4" = getprop ]; then printf '[ro.product.model]: [Mock]\\n'; exit 0; fi
        printf '%s|' "$@" | tr '\\n' ' ' >> "$root/calls"; printf '\\n' >> "$root/calls"
        case "$*" in
          *VIOLET_PARTITIONS_V1*)
            cat "$root/partitions"
            ;;
          *LONG*)
            touch "$root/long-started"; sleep 0.4; touch "$root/long-completed"; printf 'Success\\n';;
          *NEXT*) touch "$root/next-started"; printf 'Success\\n';;
          *)
            if [ "$3" = exec-out ]; then /usr/bin/python3 -c 'import os;os.write(1,b"x"*4096)'
            else printf 'Success\\n'; fi
            ;;
        esac
        """
        let url = root.appendingPathComponent("adb"); try script.write(to: url, atomically: true, encoding: .utf8)
        try "VIOLET_PARTITIONS_V1\nboot_a\t4096\t/dev/block/sda1\nboot_b\t4096\t/dev/block/sda2\nmodemst1\t4096\t/dev/block/sda3\n".write(to: root.appendingPathComponent("partitions"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: url.path)
        let fastboot = root.appendingPathComponent("fastboot"); try "#!/bin/sh\nexit 0\n".write(to: fastboot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: fastboot.path)
        let model = AppModel(); model.customDirectory = root.path
        return (model,root)
    }
    private func idle(_ model: AppModel) async throws {
        for _ in 0..<600 { if !model.busy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("operation did not finish"); await model.shutdown()
    }
    private func read(_ model: AppModel) async throws {
        await model.refresh(); model.selectedID = "adb:one"; model.selectionChanged(); model.readDevicePartitionTable(); try await idle(model)
        XCTAssertTrue(model.partitionTableReady); XCTAssertEqual(model.devicePartitions.count, 3)
    }
    func testPartitionWriteReviewFiltersProtectedTargetsAndCapturesSerial() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await read(model)
        let image = root.appendingPathComponent("boot.img"); try Data(repeating: 65, count: 512).write(to: image)
        model.partitionImages = ["boot_a":image,"modemst1":image]
        model.reviewPartitionWrites(["boot_a","modemst1"], protect: true); try await idle(model)
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.detail.contains("boot_a")); XCTAssertFalse(pending.detail.contains("modemst1"))
        XCTAssertTrue(pending.detail.contains("序列号：one")); XCTAssertTrue(model.log.contains("保护已启用，跳过：modemst1"))
        var calls = try String(contentsOf: root.appendingPathComponent("calls")); XCTAssertFalse(calls.contains("|push|"))
        model.selectedID = "adb:two"; model.selectionChanged(); pending.action(); try await idle(model)
        calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertTrue(calls.contains("|push|")); XCTAssertTrue(calls.contains("dd if=")); XCTAssertTrue(calls.contains("of="))
        XCTAssertFalse(calls.contains("-s|two|")); XCTAssertNil(model.error)
    }
    func testChangedImageAfterReviewStopsBeforeAnyDeviceWrite() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await read(model)
        let image = root.appendingPathComponent("boot.img"); try Data(repeating: 65, count: 512).write(to: image)
        model.partitionImages = ["boot_a":image]; model.reviewPartitionWrites(["boot_a"], protect: true); try await idle(model)
        let pending = try XCTUnwrap(model.pending)
        try Data([1]).write(to: image); pending.action(); try await idle(model)
        XCTAssertNotNil(model.error)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"))
        XCTAssertFalse(calls.contains("|push|")); XCTAssertFalse(calls.contains("dd if="))
    }
    func testChangedPartitionMappingAfterReviewStopsBeforePush() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await read(model)
        let image = root.appendingPathComponent("boot.img"); try Data(repeating: 65, count: 512).write(to: image)
        model.partitionImages = ["boot_a":image]; model.reviewPartitionWrites(["boot_a"], protect: true); try await idle(model)
        let pending = try XCTUnwrap(model.pending), metadata = root.appendingPathComponent("partitions")
        try String(contentsOf: metadata).replacingOccurrences(of: "/dev/block/sda1", with: "/dev/block/sda99").write(to: metadata, atomically: true, encoding: .utf8)
        pending.action(); try await idle(model)
        XCTAssertTrue(model.error?.contains("已变化") == true)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("calls")).contains("|push|"))
    }
    func testSideloadModeDoesNotReuseShellPartitionTable() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await read(model)
        model.devices = Device.parseADB("one sideload\n")
        XCTAssertFalse(model.partitionTableReady)
    }
    func testBoundaryCancellationCompletesCurrentCommandAndNeverStartsNext() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await model.refresh(); model.selectedID = "adb:one"
        let device = try XCTUnwrap(model.selected)
        model.perform("模拟写入", stopAtBoundary: true) {
            _ = try await model.execute("adb", ["shell","LONG"], device: device)
            try model.workControl.check()
            _ = try await model.execute("adb", ["shell","NEXT"], device: device)
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("long-started").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("long-started").path))
        model.cancel(); try await idle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("long-completed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("next-started").path))
        XCTAssertFalse(model.cancellationAtBoundary)
    }
    func testStreamingReadKeepsBinaryOutOfLogAndBindsDevice() async throws {
        let (model,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await read(model)
        let device = try XCTUnwrap(model.selected), partition = try XCTUnwrap(model.devicePartitions.first), output = root.appendingPathComponent("backup.img")
        model.perform("回读测试") { _ = try await model.executeStream(PartitionCommands.readRaw(partition), device: device, to: output, expectedSize: partition.size) }
        try await idle(model)
        XCTAssertEqual(try Data(contentsOf: output), Data(repeating: 120, count: 4096))
        XCTAssertFalse(model.log.contains(String(repeating: "x", count: 100)))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("calls")).contains("-s|one|exec-out|"))
    }
}
