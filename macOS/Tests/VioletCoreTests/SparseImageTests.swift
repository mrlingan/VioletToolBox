import XCTest
@testable import VioletCore

enum SparseFixture {
    struct Chunk { let type: UInt16; let blocks: UInt32; var data = Data() }
    static func le(_ value: UInt64, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        }
        return value ^ UInt32.max
    }
    static func image(_ chunks: [Chunk], checksum: UInt32 = 0, extraHeader: Int = 0, extraChunk: Int = 0) -> Data {
        let blocks = chunks.reduce(UInt64(0)) { $0 + UInt64($1.blocks) }
        var data = le(0xed26ff3a, 4) + le(1, 2) + le(0, 2) + le(UInt64(28 + extraHeader), 2) + le(UInt64(12 + extraChunk), 2)
        data += le(4096, 4) + le(blocks, 4) + le(UInt64(chunks.count), 4) + le(UInt64(checksum), 4) + Data(count: extraHeader)
        for chunk in chunks {
            data += le(UInt64(chunk.type), 2) + le(0, 2) + le(UInt64(chunk.blocks), 4) + le(UInt64(12 + extraChunk + chunk.data.count), 4)
            data += Data(count: extraChunk) + chunk.data
        }
        return data
    }
    static func save(_ data: Data, name: String, root: URL) throws -> URL { let url = root.appendingPathComponent(name); try data.write(to: url); return url }
}

final class SparseImageTests: XCTestCase {
    func testRawFillDontCareAndCumulativeCRCWithExtendedHeaders() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = Data(repeating: 65, count: 4096), pattern = Data([0x12, 0x34, 0x56, 0x78])
        let filled = Data((0..<8192).map { pattern[$0 % 4] })
        let prefix = raw + filled, expected = prefix + Data(count: 4096) + Data(repeating: 66, count: 4096)
        let chunks: [SparseFixture.Chunk] = [
            .init(type: 0xcac1, blocks: 1, data: raw), .init(type: 0xcac2, blocks: 2, data: pattern),
            .init(type: 0xcac4, blocks: 0, data: SparseFixture.le(UInt64(SparseFixture.crc(prefix)), 4)),
            .init(type: 0xcac3, blocks: 1), .init(type: 0xcac1, blocks: 1, data: Data(repeating: 66, count: 4096))
        ]
        let source = try SparseFixture.save(SparseFixture.image(chunks, checksum: SparseFixture.crc(expected), extraHeader: 4, extraChunk: 4), name: "sample.img", root: root)
        let document = try SparseImage.inspect(source)
        XCTAssertTrue(document.hasCRC); XCTAssertEqual(document.expandedSize, UInt64(expected.count))
        let output = try document.expand(to: root.appendingPathComponent("raw.img"))
        XCTAssertEqual(try Data(contentsOf: output), expected)
    }

    func testSparseHoleBeyondFourGiBUsesCorrect64BitOffsetAndCRC() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        // Independently generated with Python zlib over 4 GiB + 4096 zero bytes.
        let blocks: UInt32 = 1_048_577
        let source = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac3, blocks: blocks)], checksum: 0xb875d37f), name: "large.sparse", root: root)
        let document = try SparseImage.inspect(source), total = UInt64(4096) * UInt64(blocks)
        let output = try document.expand(to: root.appendingPathComponent("large.raw"))
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        XCTAssertEqual(size?.uint64Value, total)
        let reader = try FileHandle(forReadingFrom: output); defer { try? reader.close() }
        XCTAssertEqual(try reader.readExactly(offset: 1 << 32, count: 4096, fileSize: total), Data(count: 4096))
    }

    func testCRCErrorsRemoveOutputAndDoNotOverwriteExistingFile() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for chunks in [[SparseFixture.Chunk(type: 0xcac3, blocks: 1)], [.init(type: 0xcac3, blocks: 1), .init(type: 0xcac4, blocks: 0, data: Data(count: 4))]] {
            let source = try SparseFixture.save(SparseFixture.image(chunks, checksum: 1), name: "bad.img", root: root)
            let document = try SparseImage.inspect(source), output = root.appendingPathComponent("raw.img")
            XCTAssertThrowsError(try document.expand(to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let source = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac3, blocks: 1)]), name: "ok.img", root: root)
        let output = root.appendingPathComponent("existing.img"); try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try SparseImage.inspect(source).expand(to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }

    func testSparseSegmentsOverlayHolesAndPermitIdenticalRepeatedData() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = Data(repeating: 65, count: 4096), b = Data(repeating: 66, count: 4096)
        let first = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac1, blocks: 1, data: a), .init(type: 0xcac3, blocks: 3)]), name: "super.0.carrier.img", root: root)
        let second = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac1, blocks: 1, data: a), .init(type: 0xcac3, blocks: 1), .init(type: 0xcac1, blocks: 1, data: b), .init(type: 0xcac2, blocks: 1, data: Data(count: 4))]), name: "super.1.carrier.img", root: root)
        let out = try SuperSegments.merge([second, first], to: root.appendingPathComponent("super.img"))
        XCTAssertEqual(try Data(contentsOf: out), a + Data(count: 4096) + b + Data(count: 4096))
    }

    func testOverlappingDifferentDataAndZeroFillCannotEraseAnotherSegment() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac1, blocks: 1, data: Data(repeating: 65, count: 4096))]), name: "super_0.img", root: root)
        for chunk in [SparseFixture.Chunk(type: 0xcac1, blocks: 1, data: Data(repeating: 66, count: 4096)), .init(type: 0xcac2, blocks: 1, data: Data(count: 4))] {
            let second = try SparseFixture.save(SparseFixture.image([chunk]), name: "super_1.img", root: root)
            let out = root.appendingPathComponent("super.img")
            XCTAssertThrowsError(try SuperSegments.merge([first, second], to: out))
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    func testRawConcatenationSortingAndSegmentValidation() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try SparseFixture.save(Data("one".utf8), name: "super.img.1", root: root)
        let two = try SparseFixture.save(Data("two".utf8), name: "super.img.2", root: root)
        let out = try SuperSegments.merge([two, one], to: root.appendingPathComponent("super.img"))
        XCTAssertEqual(try Data(contentsOf: out), Data("onetwo".utf8))
        let gap = root.appendingPathComponent("super_3.img")
        XCTAssertThrowsError(try SuperSegments.sorted([one, gap]))
        XCTAssertThrowsError(try SuperSegments.sorted([one, root.appendingPathComponent("super_1.img")]))
        XCTAssertThrowsError(try SuperSegments.sorted([two, gap]))
        XCTAssertThrowsError(try SuperSegments.merge([one, two], to: one))
        XCTAssertEqual(try Data(contentsOf: one), Data("one".utf8))
    }

    func testMixedFormatsDifferentLayoutsAndMalformedHeadersAreRejected() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac3, blocks: 1)]), name: "super0.img", root: root)
        let second = try SparseFixture.save(Data("raw".utf8), name: "super1.img", root: root)
        XCTAssertThrowsError(try SuperSegments.merge([first, second], to: root.appendingPathComponent("out.img")))
        try SparseFixture.image([.init(type: 0xcac3, blocks: 2)]).write(to: second)
        XCTAssertThrowsError(try SuperSegments.merge([first, second], to: root.appendingPathComponent("out.img")))
        let valid = SparseFixture.image([.init(type: 0xcac1, blocks: 1, data: Data(count: 4096))])
        for data in [Data(valid.dropLast()), valid + Data([0]), SparseFixture.image([.init(type: 0xffff, blocks: 1)]), SparseFixture.image([.init(type: 0xcac1, blocks: 1, data: Data([0]))])] {
            let file = try SparseFixture.save(data, name: "invalid.img", root: root)
            XCTAssertThrowsError(try SparseImage.inspect(file))
        }
    }

    func testCancellationAndChangedSourceDoNotLeaveHalfImage() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try SparseFixture.save(SparseFixture.image([.init(type: 0xcac1, blocks: 512, data: Data(repeating: 65, count: 2 * 1024 * 1024))]), name: "sample.img", root: root)
        let document = try SparseImage.inspect(source), token = WorkControl(), out = root.appendingPathComponent("out.img")
        XCTAssertThrowsError(try document.expand(to: out, control: token) { _ in token.cancel() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        try Data([0]).write(to: source)
        XCTAssertThrowsError(try document.expand(to: out))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }

    func testProfileMapsDistinctCarrierGroupsFromSelectedSegments() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = try ["super.0.a.img", "super.1.a.img", "super.0.b.img", "super.1.b.img"].map { try SparseFixture.save(Data([1]), name: $0, root: root) }
        let xml = #"<profile><carrier text="A" super0=".\super.0.a.img" super1="super.1.a.img"/><carrier text="B" super0="super.0.b.img" super1="super.1.b.img"/></profile>"#
        try xml.write(to: root.appendingPathComponent("ProFile.xml"), atomically: true, encoding: .utf8)
        let variants = try SuperSegments.variants(for: urls)
        XCTAssertEqual(variants.map(\.name), ["A", "B"])
        XCTAssertEqual(variants[0].segments.map(\.lastPathComponent), ["super.0.a.img", "super.1.a.img"])
    }
}
