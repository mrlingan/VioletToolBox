import XCTest
@testable import VioletCore

final class DevicePartitionsTests: XCTestCase {
    func testFastbootParsesBothOutputStreamsPrefixesAndHexSizes() throws {
        let output = "(bootloader) partition-size:boot_a:0x06000000\nINFOpartition-type:boot_a:raw\n(bootloader) partition-size:userdata:0000000100000000\nFinished. Total time: 0.002s\n"
        let partitions = try PartitionCommands.parseFastboot(output)
        XCTAssertEqual(partitions.map(\.name), ["boot_a","userdata"])
        XCTAssertEqual(partitions[0].size, 0x6000000); XCTAssertEqual(partitions[0].type, "raw")
        XCTAssertEqual(partitions[1].size, 1 << 32)
        XCTAssertEqual(try PartitionCommands.parseFastboot("partition-size:userdata:0x20000000000").first?.size, 1 << 41)
        XCTAssertThrowsError(try PartitionCommands.parseFastboot("FAILED (remote: unknown command)"))
        XCTAssertThrowsError(try PartitionCommands.parseFastboot(output + "partition-size:boot_a:8"))
        XCTAssertThrowsError(try PartitionCommands.parseFastboot("partition-size:boot;reboot:0x4000"))
    }
    func testADBMetadataAndProtectionMatchWindowsPolicy() throws {
        let rows = "VIOLET_PARTITIONS_V1\nboot_a\t67108864\t/dev/block/sda1\nmodemst1_a\t8388608\t/dev/block/sda2\npersist\t33554432\t/dev/block/sda3\nuserdata\t4294967296\t/dev/block/dm-0\n"
        let partitions = try PartitionCommands.parseADB(rows)
        XCTAssertEqual(partitions.count, 4)
        XCTAssertTrue(PartitionCommands.protected(partitions.first { $0.name == "modemst1_a" }!, adb: false))
        XCTAssertFalse(PartitionCommands.protected(partitions.first { $0.name == "persist" }!, adb: true))
        XCTAssertTrue(PartitionCommands.protected(partitions.first { $0.name == "userdata" }!, adb: true))
        XCTAssertFalse(PartitionCommands.protected(partitions.first { $0.name == "userdata" }!, adb: false))
        XCTAssertThrowsError(try PartitionCommands.parseADB("VIOLET_PARTITIONS_V1\nboot\t0\t/dev/block/sda1"))
        XCTAssertThrowsError(try PartitionCommands.parseADB(rows + "boot_a\t67108864\t/dev/block/sda1"))
        XCTAssertThrowsError(try PartitionCommands.parseADB("VIOLET_PARTITIONS_V1\nboot\t1\t/tmp/x"))
        XCTAssertThrowsError(try PartitionCommands.blockPath("/dev/block/../tmp/x"))
    }
    func testBinaryReadAndWriteAreQuotedAndEraseIsCapacityBounded() throws {
        let part = try DevicePartition(name: "boot_a", size: 1048576 + 512, blockPath: "/dev/block/sda1")
        let read = try PartitionCommands.readRaw(part)
        XCTAssertEqual(read.first, "exec-out"); XCTAssertTrue(read[1].contains("su -c")); XCTAssertTrue(read[1].contains("bs=1048576"))
        let write = try PartitionCommands.write(part, remoteImage: "/data/local/tmp/a ' b.img")
        XCTAssertEqual(write.first, "shell"); XCTAssertTrue(write.joined().contains("conv=fsync"))
        let erase = try PartitionCommands.erase(part).joined()
        XCTAssertTrue(erase.contains("bs=1048576 count=1")); XCTAssertTrue(erase.contains("bs=512 seek=2048 count=1"))
        XCTAssertThrowsError(try PartitionCommands.erase(DevicePartition(name: "x", size: 513, blockPath: "/dev/block/sda1")))
        XCTAssertThrowsError(try PartitionCommands.readRaw(DevicePartition(name: "boot", size: 1024)))
    }
}
