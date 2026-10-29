import XCTest
@testable import VioletCore

private actor ModuleRecorder {
    var commands: [[String]] = []
    var completed: [String] = []
    let failInstall: Bool
    let cancelPush: WorkControl?
    init(failInstall: Bool = false, cancelPush: WorkControl? = nil) { self.failInstall = failInstall; self.cancelPush = cancelPush }
    func execute(_ arguments: [String], timeout: Double) throws {
        commands.append(arguments)
        if arguments.first == "push" { cancelPush?.cancel() }
        if failInstall && arguments.joined().contains("--install-module") { throw InputError.invalid("fixture installation failure") }
    }
    func snapshot() -> [[String]] { commands }
    nonisolated var executor: RootModuleCommands.Execute { { args, timeout in try await self.execute(args, timeout: timeout) } }
}

final class RootModulesTests: XCTestCase {
    func testModuleZIPReadsPropertiesAndHashesWithoutRunningScripts() throws {
        let package = try ModulePackage.open(BootAVBFixture.file("module_one.zip"))
        XCTAssertEqual(package.id, "test.one"); XCTAssertEqual(package.properties.name, "Test One")
        XCTAssertEqual(package.properties.version, "1.0"); XCTAssertEqual(package.sha256.count, 64)
        XCTAssertEqual(try ModulePackage.open(BootAVBFixture.file("module_two.zip")).id, "test.two")
    }
    func testRejectsDuplicateMetadataUnsafeIDsAndOversizedOrInvalidProperties() throws {
        for name in ["module_bad.zip", "module_duplicate.zip", "RSA2048.pem"] {
            XCTAssertThrowsError(try ModulePackage.open(BootAVBFixture.file(name)), name)
        }
        for text in ["id=../bad\n", "id=a\nid=b\n", "id=a\0", "name=missing id", "id=a\n" + String(repeating: "x", count: 65536)] {
            XCTAssertThrowsError(try ModuleProperties(data: Data(text.utf8)))
        }
        XCTAssertThrowsError(try ModuleProperties(data: Data([0xff])))
    }
    func testProbeRequiresRootMarkerAndValidManagerBinary() throws {
        let version = Data("v1.0".utf8).base64EncodedString()
        let managers = try RootModuleCommands.managers("VIOLET_ROOT_V1\nKernelSU\t/data/adb/ksud\t\(version)\nMagisk\t/sbin/magisk\t\(version)\n")
        XCTAssertEqual(managers.count, 2); XCTAssertEqual(managers[0].version, "v1.0")
        for response in ["Permission denied", "VIOLET_ROOT_V1\nMagisk\t/sbin/magisk;evil\t\(version)", "VIOLET_ROOT_V1\nUnknown\t/bin/x\t\(version)"] {
            XCTAssertThrowsError(try RootModuleCommands.managers(response))
        }
    }
    func testInstalledModulesDecodeStatesAndRejectDirectoryMismatch() throws {
        let metadata = Data("id=test.one\nname=Fixture\nversion=1\n".utf8).base64EncodedString()
        let modules = try RootModuleCommands.modules("VIOLET_MODULES_V1\ntest.one\t1\t0\t1\t\(metadata)\n")
        XCTAssertTrue(modules[0].disabled); XCTAssertFalse(modules[0].removing); XCTAssertTrue(modules[0].updating)
        XCTAssertThrowsError(try RootModuleCommands.modules("VIOLET_MODULES_V1\nwrong\t0\t0\t0\t\(metadata)"))
        XCTAssertThrowsError(try RootModuleCommands.modules("VIOLET_MODULES_V1\ntest.one\t9\t0\t0\t\(metadata)"))
        XCTAssertTrue(try RootModuleCommands.modules("VIOLET_MODULES_V1\n").isEmpty)
    }
    func testMarkerActionsNeverDeleteModuleDirectoryAndQuoteArguments() throws {
        let script = try RootModuleCommands.change(id: "test.one", action: .remove)
        XCTAssertTrue(script.contains("touch '/data/adb/modules/test.one/remove'"))
        XCTAssertFalse(script.contains("rm -rf")); XCTAssertTrue(script.contains("! -L"))
        XCTAssertTrue(try RootModuleCommands.change(id: "test.one", action: .enable).contains("rm -f '/data/adb/modules/test.one/disable'"))
        XCTAssertThrowsError(try RootModuleCommands.change(id: "x';reboot", action: .disable))
        let ksu = try RootManager(kind: .kernelSU, binary: "/data/adb/ksud", version: "test")
        XCTAssertEqual(try RootModuleCommands.change(id: "test.one", action: .undoRemove, manager: ksu), "'/data/adb/ksud' module undo-uninstall 'test.one'")
        let manager = try RootManager(kind: .magisk, binary: "/sbin/magisk", version: "test")
        XCTAssertEqual(manager.installScript(zip: "/tmp/a b.zip"), "'/sbin/magisk' --install-module '/tmp/a b.zip'")
        XCTAssertTrue(RootModuleCommands.shell("echo 'a'")[1].hasPrefix("su -c '"))
    }
    func testBatchInstallSequenceAndUniqueCleanupDirectory() async throws {
        let packages = try ["module_one.zip", "module_two.zip"].map { try ModulePackage.open(BootAVBFixture.file($0)) }
        let manager = try RootManager(kind: .magisk, binary: "/sbin/magisk", version: "fixture"), recorder = ModuleRecorder()
        try await RootModuleCommands.install(packages, manager: manager, control: WorkControl(), execute: recorder.executor, cleanup: recorder.executor)
        let commands = await recorder.snapshot()
        XCTAssertEqual(commands.count, 6)
        XCTAssertTrue(commands[0].joined().contains("umask 077; mkdir"))
        XCTAssertEqual(commands[1][0], "push"); XCTAssertEqual(commands[3][0], "push")
        XCTAssertTrue(commands[2].joined().contains("--install-module")); XCTAssertTrue(commands[4].joined().contains("--install-module"))
        XCTAssertTrue(commands[5].joined().contains("rm -rf '/data/local/tmp/violet-modules-"))
        XCTAssertEqual(URL(fileURLWithPath: commands[1][2]).deletingLastPathComponent(), URL(fileURLWithPath: commands[3][2]).deletingLastPathComponent())
    }
    func testFailureStopsNextModuleAndCleansTemporaryFiles() async throws {
        let packages = try ["module_one.zip", "module_two.zip"].map { try ModulePackage.open(BootAVBFixture.file($0)) }
        let manager = try RootManager(kind: .magisk, binary: "/sbin/magisk", version: "fixture"), recorder = ModuleRecorder(failInstall: true)
        do { try await RootModuleCommands.install(packages, manager: manager, control: WorkControl(), execute: recorder.executor, cleanup: recorder.executor); XCTFail("should stop") } catch { }
        let commands = await recorder.snapshot()
        XCTAssertEqual(commands.filter { $0.first == "push" }.count, 1)
        XCTAssertTrue(commands.last!.joined().contains("rm -rf"))
    }
    func testCancelAfterPushNeverRunsRootScriptAndStillCleans() async throws {
        let package = try ModulePackage.open(BootAVBFixture.file("module_one.zip")), control = WorkControl()
        let manager = try RootManager(kind: .kernelSU, binary: "/data/adb/ksud", version: "fixture"), recorder = ModuleRecorder(cancelPush: control)
        do { try await RootModuleCommands.install([package], manager: manager, control: control, execute: recorder.executor, cleanup: recorder.executor); XCTFail("should cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let commands = await recorder.snapshot()
        XCTAssertFalse(commands.joined().joined().contains("module install")); XCTAssertTrue(commands.last!.joined().contains("rm -rf"))
    }
    func testChangedPackageOrDuplicateIDFailsBeforeDeviceCommands() async throws {
        let root = try PayloadFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("module.zip"); try FileManager.default.copyItem(at: BootAVBFixture.file("module_one.zip"), to: url)
        let package = try ModulePackage.open(url), manager = try RootManager(kind: .apatch, binary: "/data/adb/apd", version: "fixture"), recorder = ModuleRecorder()
        try Data([1]).write(to: url)
        do { try await RootModuleCommands.install([package], manager: manager, control: WorkControl(), execute: recorder.executor, cleanup: recorder.executor); XCTFail("changed") } catch { }
        do { try await RootModuleCommands.install([package,package], manager: manager, control: WorkControl(), execute: recorder.executor, cleanup: recorder.executor); XCTFail("duplicate") } catch { }
        let commands = await recorder.snapshot(); XCTAssertTrue(commands.isEmpty)
    }
}
