import XCTest
import CryptoKit
@testable import VioletCore

final class FirmwarePackageTests: XCTestCase {
    struct Manifest: Decodable {
        struct Expected: Decodable { let size: Int; let sha256: String }
        struct Vector: Decodable { let version: Int; let length: Int; let ciphertext: String }
        let packages: [String: [String: Expected]]
        let vectors: [Vector]
    }
    var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }
    func manifest() throws -> Manifest { try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("firmware_manifest.json"))) }
    func hex(_ value: String) -> Data {
        let chars = Array(value.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }
    func pattern(_ length: Int) -> Data { Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }) }

    func testAESCFBMatchesNISTIncludingPartialAndStreamedBlocks() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c"), iv = hex("000102030405060708090a0b0c0d0e0f")
        let ciphertext = hex("3b3fd92eb72dad20333449f8e83cfb4a c8a64537a0b3a93fcde3cdad9f1ce58b 26751f67a3cbb140b1808cf187a4f4df c04b05357c5d1c0eeac4c66f9ff7f2e6")
        let plaintext = hex("6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51 30c81c46a35ce411e5fbc1191a0a52ef f69f2445df4f9b17ad2b417be66c3710")
        for length in [1, 7, 16, 17, 31, 64] {
            let input = Data(ciphertext.prefix(length))
            XCTAssertEqual(try FirmwareDecryptor.decrypt(input, cipher: .aes(key: key, iv: iv)), plaintext.prefix(length))
            let streamed = try FirmwareDecryptor(.aes(key: key, iv: iv), length: UInt64(length))
            var result = Data()
            for start in stride(from: 0, to: input.count, by: 5) { result += try streamed.update(input.subdata(in: start..<min(start + 5, input.count))) }
            result += try streamed.finish()
            XCTAssertEqual(result, plaintext.prefix(length))
        }
    }

    func testOPSMatchesIndependentReferenceVectorsForAllMboxes() throws {
        for vector in try manifest().vectors {
            let encoded = try XCTUnwrap(Data(base64Encoded: vector.ciphertext))
            let result = try FirmwareDecryptor.decrypt(encoded, cipher: .ops(version: vector.version))
            XCTAssertEqual(result, pattern(vector.length), "MBox \(vector.version), length \(vector.length)")
            let streamed = try FirmwareDecryptor(.ops(version: vector.version), length: UInt64(vector.length))
            var data = Data()
            for start in stride(from: 0, to: encoded.count, by: 16) { data += try streamed.update(encoded.subdata(in: start..<min(start + 16, encoded.count))) }
            data += try streamed.finish()
            XCTAssertEqual(data, result)
        }
    }

    func testAllOFPAndOPSPackagesMatchIndependentGoldenHashes() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, expected) in try manifest().packages {
            let document = try FirmwarePackage.open(fixtures.appendingPathComponent(name))
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let files = try document.extract(names: Set(document.entries.map(\.path)), to: directory)
            XCTAssertEqual(files.count, expected.count, name)
            for (path, golden) in expected {
                let data = try Data(contentsOf: directory.appendingPathComponent(path))
                XCTAssertEqual(data.count, golden.size, path)
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), golden.sha256, "\(name):\(path)")
            }
            if name.contains("MTK") { if case .ofpMediaTek = document.format { } else { XCTFail(name) } }
            if name.contains("QC") { if case .ofpQualcomm = document.format { } else { XCTFail(name) } }
            if name.contains("MBOX") { XCTAssertEqual(document.entries.filter(\.encrypted).count, 2) }
        }
    }

    func testSelectiveExtractionAndNestedPaths() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try FirmwarePackage.open(fixtures.appendingPathComponent("TEST_ONLY_MBOX4.ops"))
        let files = try document.extract(names: ["images/boot.img"], to: root)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/boot.img")), Data(repeating: 66, count: 4096))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prog_firehose.bin").path))
    }

    func testRejectsTraversalDuplicateRangeAndEntityDeclarations() throws {
        for bad in ["traversal", "duplicate", "range", "entity"] {
            XCTAssertThrowsError(try FirmwarePackage.open(fixtures.appendingPathComponent("TEST_BAD_\(bad).ops")), bad)
        }
        XCTAssertThrowsError(try FirmwareXML.parse("<!DOCTYPE x [<!ENTITY a 'xxx'>]><x>&a;</x>"))
        XCTAssertEqual(try ArchivePaths.normalize(".\\images\\boot.img"), "images/boot.img")
        for path in ["/tmp/image", "C:\\image", "../image", "images/../image", "./", "bad\0.img"] { XCTAssertThrowsError(try ArchivePaths.normalize(path)) }
    }

    func testExistingFilesAndSymlinkParentsAreProtectedBeforeWritingMetadata() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try FirmwarePackage.open(fixtures.appendingPathComponent("TEST_ONLY_MBOX5.ops"))
        let out = root.appendingPathComponent("out"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("images"), withDestinationURL: outside)
        XCTAssertThrowsError(try document.extract(names: ["images/boot.img"], to: out))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("settings.xml").path))
        let existing = out.appendingPathComponent("prog_firehose.bin")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try document.extract(names: ["prog_firehose.bin"], to: out))
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }

    func testCancellationRemovesHalfDecryptedEntryAndPreservesCompletedMetadata() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try FirmwarePackage.open(fixtures.appendingPathComponent("TEST_ONLY_MBOX5.ops")), token = WorkControl()
        XCTAssertThrowsError(try document.extract(names: ["prog_firehose.bin"], to: root, control: token) { _ in token.cancel() })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["settings.xml"])
    }

    func testChangedSourceAndUnknownFormatsFailWithoutOutput() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("copy.ofp"), out = root.appendingPathComponent("out")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("TEST_ONLY_MTK0.ofp"), to: source)
        let document = try FirmwarePackage.open(source)
        let handle = try FileHandle(forWritingTo: source); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        XCTAssertThrowsError(try document.extract(names: [document.entries[0].path], to: out))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        let unknown = root.appendingPathComponent("unknown.ofp")
        try Data(repeating: 0, count: 2048).write(to: unknown)
        XCTAssertThrowsError(try FirmwarePackage.open(unknown))
    }
}
