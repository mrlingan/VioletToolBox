import XCTest
import CryptoKit
@testable import VioletCore

final class OCDTTests: XCTestCase {
    func testGenerationMatchesOriginalPythonReferenceAllVariantsAndPlatforms() throws {
        struct Manifest: Decodable {
            struct Case: Decodable { let platform: String; let project: UInt16; let variant: String; let sha256: String }
            let cases: [Case]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: BootAVBFixture.root.appendingPathComponent("ocdt_manifest.json")))
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        for (i, item) in manifest.cases.enumerated() {
            let url = root.appendingPathComponent("\(i).img")
            try OCDTImage.generate(project: item.project, platform: item.platform == "mtk" ? .mtk : .qualcomm, variant: XCTUnwrap(OCDTImage.Variant(rawValue: item.variant)), to: url)
            XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: url))).hexString, item.sha256)
            let result = try OCDTImage.open(url)
            XCTAssertEqual(result.variant.rawValue, item.variant)
            if item.variant != "mixed_projid" { XCTAssertEqual(result.projectIDs, Array(repeating: UInt64(item.project), count: 3)) }
            XCTAssertFalse(result.osigHasSignature)
        }
    }
    func testBadHeadersUnsupportedMixedProjectOverwriteAndCancellation() throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("ocdt.img")
        XCTAssertThrowsError(try OCDTImage.generate(project: 1, platform: .mtk, variant: .mixed_projid, to: output))
        XCTAssertThrowsError(try OCDTImage.generate(project: 0, platform: .mtk, variant: .standard, to: output))
        let control = WorkControl(); control.cancel()
        XCTAssertThrowsError(try OCDTImage.generate(project: 1, platform: .qualcomm, variant: .standard, to: output, control: control))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try OCDTImage.open(output))
        XCTAssertThrowsError(try OCDTImage.generate(project: 1, platform: .qualcomm, variant: .standard, to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
        let invalid = root.appendingPathComponent("bad.img"); try Data(count: 131072).write(to: invalid)
        XCTAssertThrowsError(try OCDTImage.open(invalid))
    }
}
