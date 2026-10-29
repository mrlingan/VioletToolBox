import XCTest
import CryptoKit
@testable import VioletCore

enum BootAVBFixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static func file(_ name: String) -> URL { root.appendingPathComponent("TEST_ONLY_" + name) }
}

final class BootAVBTests: XCTestCase {
    func testOfficialBootImagesAllHeaderVersionsAndExportBytes() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for version in 0...4 {
            let source = BootAVBFixture.file("boot_v\(version).img"), image = try BootImage.open(source)
            XCTAssertEqual(image.version, UInt64(version)); XCTAssertEqual(image.pageSize, version < 3 ? 2048 : 4096)
            XCTAssertTrue(image.commandLine.contains("test_only=1"))
            let expected = version == 0 ? ["kernel", "ramdisk", "second"] : version == 1 ? ["kernel", "ramdisk", "second", "recovery_dtbo"] : version == 2 ? ["kernel", "ramdisk", "second", "recovery_dtbo", "dtb"] : ["kernel", "ramdisk"]
            XCTAssertEqual(image.components.map(\.name), expected)
            let output = root.appendingPathComponent("v\(version)"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            XCTAssertEqual(try image.export(to: output).count, expected.count + 1)
            for component in image.components {
                let raw = try Data(contentsOf: output.appendingPathComponent(component.name + ".bin"))
                let prefix = "TEST_ONLY_" + (component.name == "recovery_dtbo" ? "dtbo" : component.name) + "|"
                XCTAssertTrue(raw.starts(with: Data(prefix.utf8)))
                XCTAssertEqual(UInt64(raw.count), component.size)
            }
        }
    }
    func testInitBootDoesNotInventKernel() throws {
        let image = try BootImage.open(BootAVBFixture.file("init_boot.img"))
        XCTAssertEqual(image.version, 4); XCTAssertEqual(image.components.map(\.name), ["ramdisk"])
        XCTAssertEqual(image.components.first?.offset, 4096)
    }
    func testBootRejectsTruncationUnknownVersionAndBadPageOrHeader() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: BootAVBFixture.file("boot_v2.img"))
        var cases = [Data(original.prefix(100)), Data(original.prefix(5000))]
        for (offset, value) in [(40, 9), (36, 3000), (1644, 0), (1636, 0)] {
            var data = original; data.replaceSubrange(offset..<offset + 4, with: SparseFixture.le(UInt64(value), 4)); cases.append(data)
        }
        for (i, data) in cases.enumerated() {
            let file = try SparseFixture.save(data, name: "bad\(i).img", root: root)
            XCTAssertThrowsError(try BootImage.open(file), "case \(i)")
        }
    }
    func testBootCancellationAndChangedSource() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("boot.img"); try FileManager.default.copyItem(at: BootAVBFixture.file("boot_v4.img"), to: source)
        let image = try BootImage.open(source), control = WorkControl(); control.cancel()
        XCTAssertThrowsError(try image.export(to: root, control: control))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("kernel.bin").path))
        try Data([0]).write(to: source)
        XCTAssertThrowsError(try image.export(to: root))
    }
    func testOfficialAVB2048SHA256And4096SHA512SignaturesAndData() throws {
        for bits in [2048,4096] {
            let image = try AVBImage.open(BootAVBFixture.file("avb_\(bits).img"))
            XCTAssertEqual(image.rollbackIndex, 42); XCTAssertEqual(image.originalSize, 5217)
            XCTAssertEqual(image.hashes.first?.partition, "boot")
            let result = try image.verify()
            XCTAssertTrue(result.signature.contains("通过")); XCTAssertTrue(result.partitions.first!.contains("数据摘要通过"))
        }
    }
    func testStandaloneVbmetaRequiresPartitionAndUnsignedStaysUnsigned() throws {
        let image = try AVBImage.open(BootAVBFixture.file("vbmeta.img"))
        XCTAssertTrue(try image.verify().partitions.first!.contains("未校验"))
        XCTAssertTrue(try image.verify(images: ["boot": BootAVBFixture.file("avb_2048.img")]).partitions.first!.contains("数据摘要通过"))
        XCTAssertTrue(try AVBImage.open(BootAVBFixture.file("vbmeta_unsigned.img")).verify().signature.contains("未签名"))
    }
    func testAVBDetectsPayloadAuthenticationSignatureAndKeyTampering() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: BootAVBFixture.file("avb_2048.img"))
        // Official avbtool aligns vbmeta after the 5217-byte source at offset 8192.
        for (i, offset) in [17,8192 + 112,8192 + 256 + 64,8192 + 256 + 320 + 250].enumerated() {
            var bytes = original; bytes[offset] ^= 1
            let file = try SparseFixture.save(bytes, name: "bad\(i).img", root: root)
            XCTAssertThrowsError(try AVBImage.open(file).verify(), "tampered offset \(offset)")
        }
    }
    func testAVBRejectsOverflowTruncationAndUnsupportedAlgorithm() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: BootAVBFixture.file("vbmeta.img"))
        var huge = original; huge.replaceSubrange(12..<20, with: Data(repeating: 255, count: 8))
        var badDescriptor = original; badDescriptor.replaceSubrange(96..<104, with: Data(repeating: 255, count: 8))
        for (i, bytes) in [Data(original.prefix(200)), huge, badDescriptor].enumerated() {
            XCTAssertThrowsError(try AVBImage.open(SparseFixture.save(bytes, name: "bad\(i).img", root: root)))
        }
        var unsupported = original; unsupported.putBE(99, at: 28, bytes: 4)
        XCTAssertThrowsError(try AVBImage.open(SparseFixture.save(unsupported, name: "unknown.img", root: root)).verify())
    }
    func testNativeSignaturePKCS1PKCS8AndResignPreservesOriginalData() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for keyName in ["RSA2048.pem", "RSA2048_PKCS8.pem", "RSA4096.pem"] {
            let output = root.appendingPathComponent(keyName + ".img")
            try AVBImage.signCopy(source: BootAVBFixture.file("avb_2048.img"), destination: output, privateKey: BootAVBFixture.file(keyName), partition: "boot", partitionSize: 131072, rollback: 43, salt: Data([1,2,3]))
            let signed = try AVBImage.open(output)
            XCTAssertEqual(signed.rollbackIndex, 43); XCTAssertEqual(signed.originalSize, 5217)
            XCTAssertTrue(try signed.verify().signature.contains("通过"))
            XCTAssertEqual(try Data(contentsOf: output).prefix(5217), try Data(contentsOf: BootAVBFixture.file("avb_2048.img")).prefix(5217))
        }
    }
    func testNativeSignatureMatchesOfficialAvbtool() throws {
        guard let reference = ProcessInfo.processInfo.environment["VIOLET_AVBTOOL"] else { throw XCTSkip("Set VIOLET_AVBTOOL to an official cached avbtool.py for independent verification") }
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for bits in [2048,4096] {
            let folder = root.appendingPathComponent(String(bits)); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let output = folder.appendingPathComponent("boot.img")
            try AVBImage.signCopy(source: BootAVBFixture.file("boot_v4.img"), destination: output, privateKey: BootAVBFixture.file("RSA\(bits).pem"), partition: "boot", partitionSize: 131072)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [reference,"verify_image","--image",output.path,"--key",BootAVBFixture.file("RSA\(bits).pem").path]
            let log = Pipe(); process.standardOutput = log; process.standardError = log
            try process.run(); let data = log.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        }
    }
    func testSigningRejectsCapacityOverwriteInvalidKeyAndCancelsCleanly() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = BootAVBFixture.file("boot_v4.img"), key = BootAVBFixture.file("RSA2048.pem"), output = root.appendingPathComponent("signed.img")
        for size in [UInt64(0),65536,131073,UInt64.max] {
            XCTAssertThrowsError(try AVBImage.signCopy(source: source, destination: output, privateKey: key, partition: "boot", partitionSize: size))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertThrowsError(try AVBImage.signCopy(source: source, destination: output, privateKey: source, partition: "boot", partitionSize: 131072))
        let control = WorkControl(); control.cancel()
        XCTAssertThrowsError(try AVBImage.signCopy(source: source, destination: output, privateKey: key, partition: "boot", partitionSize: 131072, control: control))
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try AVBImage.signCopy(source: source, destination: output, privateKey: key, partition: "boot", partitionSize: 131072))
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }
}
