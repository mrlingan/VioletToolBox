import Foundation
import CryptoKit
import VioletNative

public enum RootPatchRecipe: Sendable {
    case magisk(apk: URL, architecture: String, keepVerity: Bool, keepEncryption: Bool, patchVBMeta: Bool)
    case kernelPatch(kpimg: URL, folkPatch: Bool)
    case lkm(module: URL, kmi: String, initBinary: URL? = nil)
    public var requiredTools: [String] {
        switch self { case .magisk: return ["magiskboot"]; case .kernelPatch: return ["magiskboot","kptools"]; case .lkm: return ["ksud","magiskboot"] }
    }
}

public enum NativeRootPatcher {
    public typealias Execute = @Sendable (String, [String], URL, [String: String]) async throws -> CommandResult

    public static func patch(source: URL, destination: URL, recipe: RootPatchRecipe, control: WorkControl = WorkControl(), execute: Execute) async throws -> URL {
        try control.check()
        let snapshot = try FileSnapshot(source), boot = try BootImage.open(source)
        guard snapshot.size <= 1024 * 1024 * 1024 else { throw InputError.invalid("Boot 镜像超过 1 GiB。") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw InputError.invalid("目标已存在，请另存为新文件。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-patch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let localBoot = directory.appendingPathComponent("boot.img"), patched = directory.appendingPathComponent("patched.img")
        try FileManager.default.copyItem(at: source, to: localBoot); try snapshot.validate(); try control.check()
        func run(_ tool: String, _ args: [String], env: [String: String] = [:]) async throws -> CommandResult {
            try control.check()
            let result = try await execute(tool, args, directory, env)
            try control.check()
            guard result.succeeded else { throw InputError.invalid("\(tool) 修补步骤失败（\(result.status)）：\(result.text.suffix(3000))") }
            return result
        }
        switch recipe {
        case let .magisk(apk, architecture, keepVerity, keepEncryption, patchVBMeta):
            guard ["arm64-v8a","armeabi-v7a","x86_64","x86","riscv64"].contains(architecture) else { throw InputError.invalid("不支持的 Android 目标架构。") }
            let apkSnapshot = try FileSnapshot(apk)
            guard apkSnapshot.size <= 256 * 1024 * 1024 else { throw InputError.invalid("管理器 APK 超过 256 MiB。") }
            for (member, output) in [("lib/\(architecture)/libmagiskinit.so","magiskinit"),("lib/\(architecture)/libmagisk.so","libmagisk.so"),("lib/\(architecture)/libinit-ld.so","libinit-ld.so")] {
                try control.check(); try zipMember(apk, member: member, to: directory.appendingPathComponent(output))
            }
            let hasStub = try zipMember(apk, member: "assets/stub.apk", to: directory.appendingPathComponent("stub.apk"), required: false)
            try apkSnapshot.validate()
            _ = try await run("magiskboot", ["unpack", "boot.img"])
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ramdisk.cpio").path) else { throw InputError.invalid("镜像没有 ramdisk，暂不支持此类 Magisk 修补。") }
            // cpio test: nonzero identifies already patched or unsupported ramdisks.
            let state = try await execute("magiskboot", ["cpio", "ramdisk.cpio", "test"], directory, [:])
            try control.check()
            guard state.succeeded else { throw InputError.invalid("Ramdisk 已修补或无法识别，请选择适配版本的原厂镜像。") }
            try FileManager.default.copyItem(at: directory.appendingPathComponent("ramdisk.cpio"), to: directory.appendingPathComponent("ramdisk.cpio.orig"))
            var hash = Insecure.SHA1()
            let reader = try FileHandle(forReadingFrom: localBoot); defer { try? reader.close() }
            while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { try control.check(); hash.update(data: data) }
            let config = "KEEPVERITY=\(keepVerity ? "true" : "false")\nKEEPFORCEENCRYPT=\(keepEncryption ? "true" : "false")\nRECOVERYMODE=false\nSHA1=\(Data(hash.finalize()).hexString)\n"
            try config.write(to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
            for (source, output) in [("libmagisk.so","magisk.xz"),("libinit-ld.so","init-ld.xz")] + (hasStub ? [("stub.apk","stub.xz")] : []) {
                _ = try await run("magiskboot", ["compress=xz",source,output])
            }
            let environment = ["KEEPVERITY":keepVerity ? "true" : "false", "KEEPFORCEENCRYPT":keepEncryption ? "true" : "false"]
            _ = try await run("magiskboot", ["cpio","ramdisk.cpio",
                "add 0750 init magiskinit", "mkdir 0750 overlay.d", "mkdir 0750 overlay.d/sbin",
                "add 0644 overlay.d/sbin/magisk.xz magisk.xz"] + (hasStub ? ["add 0644 overlay.d/sbin/stub.xz stub.xz"] : []) + [
                "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz", "patch", "backup ramdisk.cpio.orig",
                "mkdir 000 .backup", "add 000 .backup/.magisk config"], env: environment)
            let patchedState = try await execute("magiskboot", ["cpio","ramdisk.cpio","test"], directory, [:])
            try control.check()
            guard patchedState.status == 1, !patchedState.cancelled, !patchedState.timedOut else { throw InputError.invalid("Ramdisk 未通过 Magisk 修补状态检查。") }
            _ = try await run("magiskboot", ["repack","boot.img","patched.img"], env: ["PATCHVBMETAFLAG":patchVBMeta ? "true" : "false"])
        case let .kernelPatch(kpimg, folkPatch):
            guard boot.components.contains(where: { $0.name == "kernel" }) else { throw InputError.invalid("APatch / FolkPatch 必须选择含 kernel 的 boot.img。") }
            let kpSnapshot = try FileSnapshot(kpimg)
            guard kpSnapshot.size > 0, kpSnapshot.size <= 32 * 1024 * 1024 else { throw InputError.invalid("kpimg 大小无效。") }
            try FileManager.default.copyItem(at: kpimg, to: directory.appendingPathComponent("kpimg")); try kpSnapshot.validate()
            _ = try await run("magiskboot", ["unpack","boot.img"])
            let info = try await run("kptools", ["-i","kernel","-l"])
            guard !info.text.lowercased().contains("patched=true") else { throw InputError.invalid("内核已包含 KernelPatch，请使用原厂 boot.img。") }
            try FileManager.default.moveItem(at: directory.appendingPathComponent("kernel"), to: directory.appendingPathComponent("kernel_original"))
            _ = try await run("kptools", ["-p","-i","kernel_original"] + (folkPatch ? ["-S","su"] : []) + ["-k","kpimg","-o","kernel"])
            let check = try await run("kptools", ["-i","kernel","-l"])
            guard check.text.lowercased().contains("patched=true") else { throw InputError.invalid("KernelPatch 输出未通过修补状态检查。") }
            _ = try await run("magiskboot", ["repack","boot.img","patched.img"])
        case let .lkm(module, kmi, initBinary):
            guard kmi.range(of: "^android[0-9]+-[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw InputError.invalid("KMI 格式应如 android14-6.1。") }
            let moduleSnapshot = try FileSnapshot(module)
            guard moduleSnapshot.size > 0, moduleSnapshot.size <= 64 * 1024 * 1024 else { throw InputError.invalid("内核模块大小无效。") }
            try FileManager.default.copyItem(at: module, to: directory.appendingPathComponent("kernelsu.ko")); try moduleSnapshot.validate()
            var initArguments: [String] = []
            if let initBinary {
                let initSnapshot = try FileSnapshot(initBinary)
                guard initSnapshot.size > 0, initSnapshot.size <= 32 * 1024 * 1024 else { throw InputError.invalid("ksuinit 大小无效。") }
                try FileManager.default.copyItem(at: initBinary, to: directory.appendingPathComponent("ksuinit")); try initSnapshot.validate()
                initArguments = ["--init","ksuinit"]
            }
            _ = try await run("ksud", ["boot-patch","-b","boot.img","-m","kernelsu.ko"] + initArguments + ["--kmi",kmi,"--out",directory.path,"--out-name","patched.img"])
        }
        try control.check(); try snapshot.validate()
        let result = try BootImage.open(patched)
        guard result.version == boot.version, result.components.contains(where: { $0.name == "kernel" || $0.name == "ramdisk" }) else { throw InputError.invalid("修补输出的 Boot header 不匹配。") }
        let resultSnapshot = try FileSnapshot(patched), input = try FileHandle(forReadingFrom: patched)
        defer { try? input.close() }
        guard resultSnapshot.size > 0, resultSnapshot.size <= 1024 * 1024 * 1024 else { throw InputError.invalid("修补镜像大小异常。") }
        let output = try AtomicOutput(destination)
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { try control.check(); try output.handle.write(contentsOf: bytes) }
        try control.check(); try snapshot.validate(); try resultSnapshot.validate()
        return try output.commit()
    }

    @discardableResult private static func zipMember(_ source: URL, member: String, to target: URL, required: Bool = true) throws -> Bool {
        var data = Data(count: 32 * 1024 * 1024), count = 0, error = [CChar](repeating: 0, count: 1024)
        let result = data.withUnsafeMutableBytes { bytes in
            violet_zip_member(source.path, member, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &count, &error, error.count)
        }
        if result == 1, !required { return false }
        guard result == 0 else { throw InputError.invalid(String(cString: error)) }
        data.count = count
        let output = try AtomicOutput(target); try output.handle.write(contentsOf: data); _ = try output.commit()
        return true
    }
}
