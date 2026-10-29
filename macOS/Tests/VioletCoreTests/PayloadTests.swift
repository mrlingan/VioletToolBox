import XCTest
import CryptoKit
@testable import VioletCore

struct PayloadFixture {
    struct Operation {
        var type: UInt64 = 0
        var data = Data(repeating: 65, count: 4096)
        var extents: [(UInt64, UInt64)] = [(0, 1)]
        var hash: Data?
    }
    static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat {
            let byte = UInt8(value & 127); value >>= 7
            result.append(byte | (value == 0 ? 0 : 128))
        } while value != 0
        return result
    }
    static func number(_ key: UInt64, _ value: UInt64) -> Data { varint(key << 3) + varint(value) }
    static func bytes(_ key: UInt64, _ value: Data) -> Data { varint((key << 3) | 2) + varint(UInt64(value.count)) + value }
    static func be(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func make(_ operations: [Operation], name: String = "boot", size: UInt64 = 4096, hash: Data? = nil) -> Data {
        var blob = Data(), partition = bytes(1, Data(name.utf8))
        var info = number(1, size)
        if let hash { info += bytes(2, hash) }
        partition += bytes(7, info)
        for operation in operations {
            var encoded = number(1, operation.type) + number(2, UInt64(blob.count)) + number(3, UInt64(operation.data.count))
            for (start, count) in operation.extents { encoded += bytes(6, number(1, start) + number(2, count)) }
            if !operation.data.isEmpty { encoded += bytes(8, operation.hash ?? Data(SHA256.hash(data: operation.data))) }
            partition += bytes(8, encoded)
            blob += operation.data
        }
        let manifest = number(3, 4096) + bytes(13, partition)
        return Data("CrAU".utf8) + be(2, 8) + be(UInt64(manifest.count), 8) + be(0, 4) + manifest + blob
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("violet-payload-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class PayloadTests: XCTestCase {
    func testRawBZipAndXZProduceIdenticalVerifiedImages() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data(repeating: 65, count: 4096)
        let compressed: [(UInt64, Data)] = [
            (0, expected),
            (1, Data(base64Encoded: "QlpoOTFBWSZTWc0WFi0AAApEAIAEIAAACCAAMMwFU2piCgPF3JFOFCQzRYWLQA==")!),
            (8, Data(base64Encoded: "/Td6WFoAAAFpIt42AgAhARYAAAB0L+Wj4A//ABldACDv+7/+o7Fe5fg/sqomVfhocEFwFQ4kGM8AAAAAQDSm/gABMYAgAAAAeR+nHT4wDYsCAAAAAAFZWg==")!)
        ]
        for (type, data) in compressed {
            let input = root.appendingPathComponent("payload-\(type).bin")
            try PayloadFixture.make([.init(type: type, data: data)], hash: Data(SHA256.hash(data: expected))).write(to: input)
            let document = try PayloadArchive.open(input)
            XCTAssertEqual(document.partitions.count, 1)
            XCTAssertTrue(document.partitions[0].hasSHA256)
            let out = root.appendingPathComponent("out-\(type)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            let files = try document.extract(names: ["boot"], to: out)
            XCTAssertEqual(try Data(contentsOf: files[0]), expected)
        }
    }

    func testScatteredExtentsZerosDiscardAndPadding() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("payload.bin")
        let expected = Data(repeating: 66, count: 4096) + Data(repeating: 65, count: 4096) + Data(count: 8192) + Data([90]) + Data(count: 4095)
        let operations: [PayloadFixture.Operation] = [
            .init(data: Data(repeating: 65, count: 4096) + Data(repeating: 66, count: 4096), extents: [(1, 1), (0, 1)]),
            .init(type: 6, data: Data(), extents: [(2, 1)]), .init(type: 7, data: Data(), extents: [(3, 1)]),
            .init(data: Data([90]), extents: [(4, 1)])
        ]
        try PayloadFixture.make(operations, size: UInt64(expected.count), hash: Data(SHA256.hash(data: expected))).write(to: input)
        let document = try PayloadArchive.open(input)
        let out = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let files = try document.extract(names: ["boot"], to: out)
        XCTAssertEqual(try Data(contentsOf: files[0]), expected)
    }

    func testZIPExtractionAndTemporaryFileCleanup() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("payload.bin")
        try PayloadFixture.make([.init()]).write(to: input)
        let zip = root.appendingPathComponent("ota.zip")
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        command.arguments = ["-q", "-j", zip.path, input.path]
        try command.run(); command.waitUntilExit(); XCTAssertEqual(command.terminationStatus, 0)
        let document = try PayloadArchive.open(zip)
        XCTAssertTrue(document.isTemporary)
        XCTAssertEqual(document.originalURL, zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.sourceURL.path))
        XCTAssertEqual(document.partitions[0].name, "boot")
        document.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.sourceURL.path))
    }

    func testUnsupportedDeltaOperationCannotProduceAnImage() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("delta.bin")
        try PayloadFixture.make([.init(type: 4, data: Data())]).write(to: input)
        let document = try PayloadArchive.open(input)
        XCTAssertFalse(document.partitions[0].extractable)
        XCTAssertThrowsError(try document.extract(names: ["boot"], to: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("boot.img").path))
    }

    func testBadOperationOrPartitionHashRemovesPartialOutput() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for operationHash in [false, true] {
            let input = root.appendingPathComponent("bad-\(operationHash).bin")
            let bad = Data(repeating: 0, count: 32)
            try PayloadFixture.make([.init(hash: operationHash ? bad : nil)], hash: operationHash ? nil : bad).write(to: input)
            let output = root.appendingPathComponent("output-\(operationHash)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let document = try PayloadArchive.open(input)
            XCTAssertThrowsError(try document.extract(names: ["boot"], to: output))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
    }

    func testRejectsTraversalTruncationOverflowAndOverlappingExtents() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            PayloadFixture.make([.init()], name: "../escape"),
            Data(PayloadFixture.make([.init()]).dropLast()),
            PayloadFixture.make([.init(extents: [(UInt64.max, 1)])]),
            PayloadFixture.make([.init(), .init()])
        ]
        for (index, data) in files.enumerated() {
            let input = root.appendingPathComponent("invalid-\(index).bin"); try data.write(to: input)
            XCTAssertThrowsError(try PayloadArchive.open(input))
        }
    }

    func testCancellationAndExistingImagesArePreserved() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("payload.bin")
        try PayloadFixture.make([.init()]).write(to: input)
        let document = try PayloadArchive.open(input)
        let existing = root.appendingPathComponent("boot.img")
        try Data("original".utf8).write(to: existing)
        XCTAssertThrowsError(try document.extract(names: ["boot"], to: root))
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
        let token = WorkControl(); token.cancel()
        XCTAssertThrowsError(try PayloadArchive.open(input, control: token))
    }

    func testCancellationDuringExtractionRemovesCurrentPartition() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("payload.bin"), out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try PayloadFixture.make([.init(), .init(extents: [(1, 1)])], size: 8192).write(to: input)
        let document = try PayloadArchive.open(input), control = WorkControl()
        XCTAssertThrowsError(try document.extract(names: ["boot"], to: out, control: control) { _ in control.cancel() })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    func testZIP64ArchiveIsAccepted() throws {
        let root = try PayloadFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("payload.bin"), zip = root.appendingPathComponent("zip64.zip")
        try PayloadFixture.make([.init()]).write(to: input)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import zipfile,sys; zipfile.ZIP64_LIMIT=0; z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED); z.write(sys.argv[1],'payload.bin'); z.close()", input.path, zip.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let document = try PayloadArchive.open(zip)
        defer { document.cleanup() }
        XCTAssertEqual(document.partitions[0].name, "boot")
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let paths = try document.extract(names: ["boot"], to: out)
        XCTAssertEqual(try Data(contentsOf: paths[0]), Data(repeating: 65, count: 4096))
    }
}
