import XCTest
@testable import VioletCore

final class RemoteFilesTests: XCTestCase {
    func testRemoteDirectoryProtocolPreservesSpacesQuotesAndUnicode() throws {
        let response = "VIOLET_FILES_V1\n" + [("f",12,"a ' b.txt"),("d",0,"照片"),("l",0,"link")].map { "\($0.0)\t\($0.1)\t" + Data($0.2.utf8).base64EncodedString() }.joined(separator: "\n")
        let files = try RemoteFiles.parse(response, directory: "/sdcard//Download/")
        XCTAssertEqual(files[0].name, "照片"); XCTAssertEqual(files[1].path, "/sdcard/Download/a ' b.txt")
        XCTAssertEqual(files[1].size, 12); XCTAssertEqual(files[2].kind, .link)
    }
    func testPathValidationAndActionsQuoteShellMetacharacters() throws {
        for bad in ["relative", "/a/../b", "/x\nrm", "/x\0", "/./a"] { XCTAssertThrowsError(try RemoteFiles.path(bad)) }
        XCTAssertThrowsError(try RemoteFiles.child("../x", in: "/sdcard"))
        XCTAssertThrowsError(try RemoteFiles.child("..", in: "/sdcard"))
        XCTAssertEqual(try RemoteFiles.path("///"), "/")
        let name = "'; touch hacked; '"
        XCTAssertEqual(try RemoteFiles.create(name: name, directory: "/sdcard", folder: true), "mkdir -- " + Input.remoteQuote("/sdcard/" + name))
        XCTAssertTrue(try RemoteFiles.create(name: "x", directory: "/sdcard", folder: false).hasPrefix("set -C;"))
        XCTAssertTrue(try RemoteFiles.rename(source: "/sdcard/a", name: "b").contains("[ ! -e '/sdcard/b' ]"))
        XCTAssertThrowsError(try RemoteFiles.rename(source: "/sdcard/a", name: "a"))
        XCTAssertThrowsError(try RemoteFiles.delete(["/"]))
        XCTAssertThrowsError(try RemoteFiles.delete([]))
        XCTAssertEqual(try RemoteFiles.delete(["/sdcard/a;echo x"]), "rm -rf -- '/sdcard/a;echo x'")
    }
    func testRejectsMalformedDuplicateAndTraversingDirectoryEntries() throws {
        for response in ["Permission denied", "VIOLET_FILES_V1\nf\t-1\teA==", "VIOLET_FILES_V1\nf\t0\tLi4=", "VIOLET_FILES_V1\nf\t0\teA==\nf\t1\teA==", "VIOLET_FILES_V1\nf\t0\t/w=="] {
            XCTAssertThrowsError(try RemoteFiles.parse(response, directory: "/sdcard"), response)
        }
        XCTAssertTrue(try RemoteFiles.parse("VIOLET_FILES_V1\n", directory: "/sdcard").isEmpty)
    }
}
