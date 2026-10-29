import XCTest
@testable import VioletCore

final class NativeRootPatcherTests: XCTestCase {
    func testNativeLKMInjectionWithAllThreeBundledModuleBranches() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ksud = env["VIOLET_KSUD"], let magiskboot = env["VIOLET_MAGISKBOOT"], let initPath = env["VIOLET_KSUINIT"] else { throw XCTSkip("Set VIOLET_KSUD, VIOLET_MAGISKBOOT and VIOLET_KSUINIT for LKM integration") }
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner = CommandRunner()
        for branch in ["KernelSU","SukiSU_Ultra","ReSukiSU"] {
            let folder = root.appendingPathComponent(branch); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let module = repository.appendingPathComponent("VioletToolBox/LKM_Patch/\(branch)/android14-6.1_kernelsu.ko")
            let target = folder.appendingPathComponent("patched.img")
            try await NativeRootPatcher.patch(source: BootAVBFixture.file("patch_boot.img"), destination: target,
                recipe: .lkm(module: module, kmi: "android14-6.1", initBinary: URL(fileURLWithPath: initPath)), execute: { name, args, directory, environment in
                    try await runner.run(executable: URL(fileURLWithPath: name == "ksud" ? ksud : magiskboot), arguments: args, environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new }, timeout: 60, workingDirectory: directory)
                })
            XCTAssertEqual(try BootImage.open(target).version, 4)
            let unpack = try await runner.run(executable: URL(fileURLWithPath: magiskboot), arguments: ["unpack",target.path], workingDirectory: folder)
            XCTAssertTrue(unpack.succeeded, unpack.text)
            let extract = try await runner.run(executable: URL(fileURLWithPath: magiskboot), arguments: ["cpio","ramdisk.cpio","extract kernelsu.ko injected.ko"], workingDirectory: folder)
            XCTAssertTrue(extract.succeeded, extract.text)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("injected.ko")), try Data(contentsOf: module))
        }
    }
    func testMagiskPatchWithNativeMacToolAndOfficialAPK() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let tool = env["VIOLET_MAGISKBOOT"], let apk = env["VIOLET_MAGISK_APK"] else { throw XCTSkip("Set VIOLET_MAGISKBOOT and VIOLET_MAGISK_APK for native integration") }
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = BootAVBFixture.file("patch_boot.img"), target = root.appendingPathComponent("patched.img"), runner = CommandRunner()
        let original = try Data(contentsOf: source)
        try await NativeRootPatcher.patch(source: source, destination: target,
            recipe: .magisk(apk: URL(fileURLWithPath: apk), architecture: "arm64-v8a", keepVerity: true, keepEncryption: true, patchVBMeta: false), execute: { name, args, directory, environment in
                XCTAssertEqual(name, "magiskboot")
                return try await runner.run(executable: URL(fileURLWithPath: tool), arguments: args, environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new }, timeout: 60, workingDirectory: directory)
            })
        let output = try Data(contentsOf: target), image = try BootImage.open(target), stock = try BootImage.open(source)
        XCTAssertNotEqual(output, original); XCTAssertEqual(try Data(contentsOf: source), original)
        let kernel = try XCTUnwrap(image.components.first { $0.name == "kernel" }), originalKernel = try XCTUnwrap(stock.components.first { $0.name == "kernel" })
        XCTAssertEqual(output.subdata(in: Int(kernel.offset)..<Int(kernel.offset + kernel.size)), original.subdata(in: Int(originalKernel.offset)..<Int(originalKernel.offset + originalKernel.size)))
        let result = try await runner.run(executable: URL(fileURLWithPath: tool), arguments: ["unpack",target.path], workingDirectory: root)
        XCTAssertTrue(result.succeeded, result.text)
        let state = try await runner.run(executable: URL(fileURLWithPath: tool), arguments: ["cpio","ramdisk.cpio","test"], workingDirectory: root)
        XCTAssertEqual(state.status, 1)
        let config = try await runner.run(executable: URL(fileURLWithPath: tool), arguments: ["cpio","ramdisk.cpio","extract .backup/.magisk config"], workingDirectory: root)
        XCTAssertTrue(config.succeeded, config.text)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: root.appendingPathComponent("config").path)
        let configuration = try String(contentsOf: root.appendingPathComponent("config"))
        XCTAssertTrue(configuration.contains("KEEPVERITY=true")); XCTAssertTrue(configuration.contains("KEEPFORCEENCRYPT=true")); XCTAssertTrue(configuration.contains("SHA1="))
    }
    func testCancelledOrInvalidBootNeverStartsToolAndDoesNotCreateOutput() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("output.img"), control = WorkControl(); control.cancel()
        let recipe = RootPatchRecipe.kernelPatch(kpimg: BootAVBFixture.file("RSA2048.pem"), folkPatch: false)
        let never: NativeRootPatcher.Execute = { _, _, _, _ in XCTFail("must not launch tool"); throw CancellationError() }
        do { _ = try await NativeRootPatcher.patch(source: BootAVBFixture.file("patch_boot.img"), destination: target, recipe: recipe, control: control, execute: never); XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await NativeRootPatcher.patch(source: BootAVBFixture.file("vbmeta.img"), destination: target, recipe: recipe, execute: never); XCTFail("invalid boot") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testNoKernelAndInvalidKMIRejectBeforeTools() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("output.img")
        let never: NativeRootPatcher.Execute = { _, _, _, _ in XCTFail("must not launch tool"); throw CancellationError() }
        for recipe in [RootPatchRecipe.kernelPatch(kpimg: BootAVBFixture.file("RSA2048.pem"), folkPatch: false), .lkm(module: BootAVBFixture.file("RSA2048.pem"), kmi: "bad;cmd")] {
            do { _ = try await NativeRootPatcher.patch(source: BootAVBFixture.file("init_boot.img"), destination: target, recipe: recipe, execute: never); XCTFail("must reject") } catch { }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
