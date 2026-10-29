import XCTest
@testable import VioletCore

enum GPTFixture {
    static func components(_ sector: Int) throws -> (Data,Data) {
        (try Data(contentsOf: BootAVBFixture.file("gpt\(sector)_main.bin")), try Data(contentsOf: BootAVBFixture.file("gpt\(sector)_backup.bin")))
    }
    static func image(_ sector: Int, root: URL) throws -> URL {
        let (main, backup) = try components(sector), file = root.appendingPathComponent("disk\(sector).img")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sector * 4096)); try handle.seek(toOffset: 0); try handle.write(contentsOf: main)
        try handle.seek(toOffset: UInt64(sector * 4096 - backup.count)); try handle.write(contentsOf: backup)
        return file
    }
    static func fixHeader(_ data: inout Data, offset: Int) {
        data.replaceSubrange(offset + 16..<offset + 20, with: Data(count: 4))
        let crc = SparseFixture.crc(data.subdata(in: offset..<offset + 92))
        data.replaceSubrange(offset + 16..<offset + 20, with: SparseFixture.le(UInt64(crc), 4))
    }
}

final class GPTTests: XCTestCase {
    func testBackupGPTBeyondFourGiBRetains64BitOffsets() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var (main, backup) = try GPTFixture.components(512)
        let sectors = UInt64(8_388_608 + 4096), lastUsable = sectors - 34, backupStart = sectors - 33
        main.replaceSubrange(512 + 32..<512 + 40, with: SparseFixture.le(sectors - 1, 8))
        main.replaceSubrange(512 + 48..<512 + 56, with: SparseFixture.le(lastUsable, 8)); GPTFixture.fixHeader(&main, offset: 512)
        let headerOffset = backup.count - 512
        backup.replaceSubrange(headerOffset + 24..<headerOffset + 32, with: SparseFixture.le(sectors - 1, 8))
        backup.replaceSubrange(headerOffset + 48..<headerOffset + 56, with: SparseFixture.le(lastUsable, 8))
        backup.replaceSubrange(headerOffset + 72..<headerOffset + 80, with: SparseFixture.le(backupStart, 8)); GPTFixture.fixHeader(&backup, offset: headerOffset)
        let source = root.appendingPathComponent("large-disk.img"); FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: sectors * 512); try handle.seek(toOffset: 0); try handle.write(contentsOf: main)
        try handle.seek(toOffset: backupStart * 512); try handle.write(contentsOf: backup); try handle.close()
        let image = try await GPTDiskImage.open(source)
        XCTAssertEqual(image.backupStartLBA, backupStart); XCTAssertGreaterThan(backupStart * 512, 1 << 32)
        XCTAssertEqual(image.backupBytes, backup); XCTAssertEqual(image.partitions.count, 3)
    }
    func testIndependent512And4096FixturesValidateAndExportExactRegions() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for sector in [512,4096] {
            let image = try await GPTDiskImage.open(GPTFixture.image(sector, root: root), sectorSize: UInt64(sector))
            XCTAssertEqual(image.partitions.map(\.name), ["boot_a","persist","资料"])
            XCTAssertEqual(image.partitions.first?.sectorCount, 32)
            XCTAssertEqual(image.header.diskGUID, "12345678-9abc-def0-1122-334455667788")
            XCTAssertEqual(image.partitions[1].uniqueGUID, "00000000-0000-0000-0000-000000000002")
            XCTAssertNil(image.warning)
            let files = try image.export(to: root, prefix: "gpt\(sector)")
            XCTAssertEqual(files.count, 3)
            let expected = try GPTFixture.components(sector)
            XCTAssertEqual(try Data(contentsOf: files[0]), expected.0); XCTAssertEqual(try Data(contentsOf: files[1]), expected.1)
            XCTAssertThrowsError(try image.export(to: root, prefix: "gpt\(sector)"))
        }
    }
    func testHeaderTableCRCAndBackupMismatchAreRejected() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for offset in [512 + 16,1024 + 61,512 * 4096 - 512 + 16] {
            let file = try GPTFixture.image(512, root: root), handle = try FileHandle(forUpdating: file)
            try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: Data([0xff])); try handle.close()
            do { _ = try await GPTDiskImage.open(file); XCTFail("corrupt offset \(offset)") } catch { XCTAssertTrue(error.localizedDescription.contains("CRC"), error.localizedDescription) }
            try FileManager.default.removeItem(at: file)
        }
    }
    func testHeaderOverflowAndEntrySizeNeverTriggerReaderAllocation() async throws {
        var (main, _) = try GPTFixture.components(512)
        main.replaceSubrange(512 + 72..<512 + 80, with: Data(repeating: 255, count: 8)); GPTFixture.fixHeader(&main, offset: 512)
        let initial = main.subdata(in: 0..<1024)
        do {
            _ = try await GPTDiskImage.read(sectorSize: 512, totalSectors: 4096) { lba, sectors in
                XCTAssertEqual(lba, 0); XCTAssertEqual(sectors, 2)
                return initial
            }
            XCTFail("overflow")
        } catch { }
        var invalid = try GPTFixture.components(512).0.subdata(in: 512..<1024)
        invalid.replaceSubrange(84..<88, with: SparseFixture.le(65536, 4)); GPTFixture.fixHeader(&invalid, offset: 0)
        XCTAssertThrowsError(try GPTHeader.parse(invalid, sectorSize: 512, totalSectors: 4096, expectedLBA: 1))
    }
    func testOverlappingPartitionsAndDuplicateGUIDRejectEvenWithValidCRCs() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for overlap in [true,false] {
            var (main, backup) = try GPTFixture.components(512)
            var entries = main.subdata(in: 1024..<1024 + 16384)
            if overlap { entries.replaceSubrange(128 + 32..<128 + 48, with: entries.subdata(in: 32..<48)) }
            else { entries.replaceSubrange(128 + 16..<128 + 32, with: entries.subdata(in: 16..<32)) }
            let crc = UInt64(SparseFixture.crc(entries))
            main.replaceSubrange(1024..<1024 + 16384, with: entries); main.replaceSubrange(512 + 88..<512 + 92, with: SparseFixture.le(crc, 4)); GPTFixture.fixHeader(&main, offset: 512)
            backup.replaceSubrange(0..<16384, with: entries); backup.replaceSubrange(16384 + 88..<16384 + 92, with: SparseFixture.le(crc, 4)); GPTFixture.fixHeader(&backup, offset: 16384)
            let file = root.appendingPathComponent("invalid.img"); FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 512 * 4096); try handle.seek(toOffset: 0); try handle.write(contentsOf: main); try handle.seek(toOffset: 512 * 4096 - UInt64(backup.count)); try handle.write(contentsOf: backup); try handle.close()
            do { _ = try await GPTDiskImage.open(file); XCTFail("must reject overlap / duplicate GUID") } catch {
                XCTAssertTrue(error.localizedDescription.contains(overlap ? "重叠" : "GUID"), error.localizedDescription)
            }
            try FileManager.default.removeItem(at: file)
        }
    }
    func testCancellationAndNonGPTResponse() async throws {
        let control = WorkControl(); control.cancel()
        do { _ = try await GPTDiskImage.read(sectorSize: 512, totalSectors: 4096, control: control) { _, _ in XCTFail("cancelled before read"); return Data() }; XCTFail("cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let empty = try await GPTDiskImage.read(sectorSize: 512, totalSectors: 4096) { _, count in Data(count: Int(count * 512)) }
        XCTAssertNil(empty)
    }
}
