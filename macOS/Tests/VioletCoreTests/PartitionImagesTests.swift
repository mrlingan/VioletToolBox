import XCTest
@testable import VioletCore

final class PartitionImagesTests: XCTestCase {
    func testBackupXMLRequiresUniqueGPTMappingAndExactPhysicalSize() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try await GPTDiskImage.open(GPTFixture.image(512, root: root))
        let maps = [RawProgram.PartitionMap(lun: 0, sectorSize: 512, partitions: image.partitions)]
        let file = root.appendingPathComponent("boot_a.img"); try Data(count: 16384).write(to: file)
        let entries = try RawProgram.partitionEntries(images: ["boot_a":file], maps: maps)
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].startSector, image.partitions[0].firstLBA); XCTAssertEqual(entries[0].sectorCount, 32)
        XCTAssertThrowsError(try RawProgram.partitionEntries(images: ["boot_a":file], maps: maps + maps))
        XCTAssertThrowsError(try RawProgram.partitionEntries(images: ["missing":file], maps: maps))
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try RawProgram.partitionEntries(images: ["boot_a":file], maps: maps))
    }
    func testSparseCapacityUsesExpandedSizeAndADBMaterializesRaw() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = SparseFixture.image([.init(type: 0xcac1, blocks: 1, data: Data(repeating: 65, count: 4096)), .init(type: 0xcac3, blocks: 1)])
        let source = try SparseFixture.save(data, name: "sparse.img", root: root)
        let partition = try DevicePartition(name: "boot", size: 8192)
        let input = try PartitionImageInput.open(source, for: partition)
        XCTAssertTrue(input.isSparse); XCTAssertEqual(input.expandedSize, 8192)
        XCTAssertThrowsError(try PartitionImageInput.open(source, for: DevicePartition(name: "boot", size: 4096)))
        let raw = try input.rawFile(in: root, control: WorkControl())
        XCTAssertEqual(try Data(contentsOf: raw), Data(repeating: 65, count: 4096) + Data(count: 4096))
        let copy = try input.copySource(to: root.appendingPathComponent("stable.img"), control: WorkControl())
        XCTAssertEqual(try Data(contentsOf: copy), data)
    }
    func testChangedSourceAndCancellationNeverLeaveCommittedCopy() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try SparseFixture.save(Data(repeating: 65, count: 2 * 1024 * 1024), name: "raw.img", root: root)
        let input = try PartitionImageInput.open(source, for: DevicePartition(name: "boot", size: 4 * 1024 * 1024))
        XCTAssertFalse(input.isSparse)
        let target = root.appendingPathComponent("copy.img"), control = WorkControl()
        XCTAssertThrowsError(try input.copySource(to: target, control: control) { _ in control.cancel() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try Data([1]).write(to: source)
        XCTAssertThrowsError(try input.validate())
        XCTAssertThrowsError(try input.rawFile(in: root, control: WorkControl()))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }
    func testExternalToolOutputOnlyCommitsCorrectSizeAndSameInode() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("fetched.img")
        do {
            let output = try ExternalToolOutput(target), writer = try FileHandle(forWritingTo: output.url)
            try writer.write(contentsOf: Data("disk".utf8)); try writer.close()
            try output.commit(expectedSize: 4)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("disk".utf8))
        XCTAssertThrowsError(try ExternalToolOutput(target))
        let rejected = root.appendingPathComponent("bad.img")
        do {
            let output = try ExternalToolOutput(rejected), writer = try FileHandle(forWritingTo: output.url)
            try writer.write(contentsOf: Data("disk".utf8)); try writer.close()
            try FileManager.default.removeItem(at: output.url); try Data("evil".utf8).write(to: output.url)
            XCTAssertThrowsError(try output.commit(expectedSize: 4))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }
    func testBlockGeometryUsesLinux512UnitsAndSCSILUN() throws {
        let devices = try BlockGeometry.parse("VIOLET_BLOCKS_V1\nsda\t4096\t33554432\t/sys/devices/0:0:0:4\nmmcblk0\t512\t4194304\t/sys/devices/mmc0\n")
        XCTAssertEqual(devices.map(\.name), ["mmcblk0","sda"])
        XCTAssertEqual(devices[1].lun, 4); XCTAssertEqual(devices[1].totalSectors, 4194304); XCTAssertEqual(devices[1].byteCount, 1 << 34)
        XCTAssertTrue(try devices[1].readArguments(lba: 1, sectors: 1).joined().contains("bs=4096 skip=1 count=1"))
        XCTAssertThrowsError(try devices[1].readArguments(lba: devices[1].totalSectors, sectors: 1))
        XCTAssertThrowsError(try BlockGeometry.parse("VIOLET_BLOCKS_V1\nsda1\t512\t10000\tx"))
        XCTAssertThrowsError(try BlockGeometry.parse("VIOLET_BLOCKS_V1\nsda\t512\t18446744073709551615\tx"))
    }
    func testRawProgramEscapesXMLAndRecordsByteOffsets() throws {
        let entry = try RawProgramEntry(filename: "boot & test.img", label: "a\"<&b", lun: 2, sectorSize: 4096, startSector: 10, sectorCount: 4)
        let encoded = try RawProgram.encode([entry]), root = try FirmwareXML.parse(String(decoding: encoded, as: UTF8.self))
        let row = try XCTUnwrap(root.children.first)
        XCTAssertEqual(row.attribute("filename"), "boot & test.img"); XCTAssertEqual(row.attribute("label"), "a\"<&b")
        XCTAssertEqual(row.attribute("start_byte_hex"), "0xA000"); XCTAssertEqual(row.attribute("size_in_KB"), "16")
        XCTAssertEqual(row.attribute("physical_partition_number"), "2")
        XCTAssertThrowsError(try RawProgramEntry(filename: "../bad.img", label: "x", lun: 0, sectorSize: 512, startSector: 0, sectorCount: 1))
        XCTAssertThrowsError(try RawProgramEntry(filename: "x", label: "x", lun: 0, sectorSize: 512, startSector: UInt64.max, sectorCount: 1))
    }
}
