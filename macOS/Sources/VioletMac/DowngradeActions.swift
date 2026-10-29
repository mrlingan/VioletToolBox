import Foundation
import AppKit
import VioletCore

extension AppModel {
    func chooseDowngradeAPK() {
        if let file = chooseFiles(extensions:["apk"]).first { downgradeAPK = file }
    }
    func chooseDowngradePackage() {
        if let file = chooseFiles(extensions:["zip","ozip"]).first { downgradeLocalPackage = file }
    }
    func queryDowngrade() {
        guard let device = selected, device.shellReady else { return }
        let apk = downgradeAPK
        pending = PendingOperation(title:"查询可用降级版本",detail:"设备：\(device.label)\nADB 序列号：\(device.serial)\n\(apk.map { "将安装或更新所选 APK：\($0.path)\n" } ?? "使用已安装的 com.color.otaassistant。\n")将启动手机端降级助手，通过本机 ADB 转发读取设备信息，并将机型、当前版本、项目号、运营商、序列号与加密 DUID 提交给 ColorOS 降级查询服务。此步骤不会发送降级安装请求。") {
            self.perform("查询降级包") {
                self.downgradeCatalog = nil; self.downgradeDevice = nil
                self.downgradeVersion = nil; self.downgradeVersionPackage = nil
                try await self.startDowngradeAssistant(device:device,apk:apk)
                let serial = try await self.downgradeSerial(device)
                let info = try await self.withDowngradePort(device:device) { port in
                    try await self.readDowngradeInfo(port:port,serial:serial,device:device)
                }
                let catalog = try await DowngradeClient().query(info)
                try self.workControl.check()
                self.downgradeCatalog = catalog; self.downgradeDevice = device
                self.append("降级查询返回 \(catalog.packages.count) 个版本；机型 \(info.model)，当前 \(info.otaVersion)。")
            }
        }
    }
    func downloadDowngrade(_ package: DowngradePackage) {
        guard let target = saveURL(name:"Downgrade-\(package.id).\(package.fileExtension)") else { return }
        perform("下载降级包并校验") {
            try package.validateForInstall()
            let control = self.workControl
            let file = try await self.downloadService.download(from:package.url,to:target,control:control) { progress in Task { @MainActor in self.reportWork(progress,control:control) } }
            do {
                try await Task.detached {
                    try DowngradeFile.package(file,matching:package).verify(control:control) { progress in Task { @MainActor in self.reportWork(progress,control:control) } }
                }.value
            } catch { self.append("文件已下载到 \(file.path)，但尚未通过大小 / MD5 校验；未推送到手机。"); throw error }
            try control.check(); self.downgradeLocalPackage = file
            self.append("降级包下载和 MD5 校验完成：\(file.path)")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
    func reviewDowngradeInstall(_ package: DowngradePackage) {
        guard let catalog = downgradeCatalog, let device = downgradeDevice, catalog.packages.contains(package) else { return }
        do {
            try package.validateForInstall()
            guard let source = downgradeLocalPackage else { throw InputError.invalid("请先下载或选择本地降级包。") }
            let file = try DowngradeFile.package(source,matching:package)
            let remote = "/sdcard/VioletDowngrade-" + UUID().uuidString + "." + package.fileExtension
            pending = PendingOperation(title:"推送并提交降级安装请求",detail:"设备：\(device.label)\nADB 序列号：\(device.serial)\n设备型号：\(catalog.device.model)\n当前版本：\(catalog.device.otaVersion)\n目标版本：\(package.otaVersion)\n\(package.androidVersion) · \(package.colorOSVersion)\n\(package.fileSize) bytes · MD5 \(package.md5)\n本地：\(source.path)\n设备：\(remote)\n\n将复制并校验整个本地包，重新核对设备版本与服务端授权，推送后再次核对手机端文件。降级会清空数据；Windows 说明此流程仅适用于已熔断的 OPPO / 一加跨安卓版本降级，未熔断设备存在不可逆熔断风险。提交请求后需在手机的软件更新中按提示完成本地安装。\n\n停止在当前设备命令完成后生效。安装指令一旦发出会等待助手回应，停止不能撤回已提交的请求。") {
                self.executeDowngradeInstall(catalog:catalog,package:package,file:file,device:device,remote:remote)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func executeDowngradeInstall(catalog: DowngradeCatalog, package: DowngradePackage, file: DowngradeFile, device: Device, remote: String) {
        perform("推送并提交降级",stopAtBoundary:true) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-downgrade-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:directory) }
            let control = self.workControl
            let staged = try await Task.detached {
                try file.stage(to:directory.appendingPathComponent("package." + package.fileExtension),control:control) { progress in Task { @MainActor in self.reportWork(progress,control:control) } }
            }.value
            try control.check()
            try await self.startDowngradeAssistant(device:device,apk:nil)
            let serial = try await self.downgradeSerial(device)
            let current = try await self.withDowngradePort(device:device) { port in try await self.readDowngradeInfo(port:port,serial:serial,device:device) }
            guard current == catalog.device else { throw InputError.invalid("设备身份或当前版本与查询时不同，请重新查询。") }
            let refreshed = try await DowngradeClient().query(current)
            _ = try refreshed.refreshedPackage(matching:package)
            try control.check()
            let partial = remote + ".part"
            do {
                self.activity = "推送降级包"
                _ = try await self.execute("adb",["push",staged.path,partial],device:device,timeout:7200)
                try control.check()
                let check = """
                file=\(Input.remoteQuote(partial))
                [ -f "$file" ] && [ ! -L "$file" ] || exit 71
                [ "$(stat -c %s "$file")" = \(Input.remoteQuote(String(package.fileSize))) ] || exit 72
                digest=$(md5sum "$file") || exit 73
                [ "${digest%% *}" = \(Input.remoteQuote(package.md5)) ] || exit 74
                [ ! -e \(Input.remoteQuote(remote)) ] && [ ! -L \(Input.remoteQuote(remote)) ] || exit 75
                mv -- "$file" \(Input.remoteQuote(remote)) || exit 76
                """
                _ = try await self.execute("adb",["shell",check],device:device,timeout:7200)
                try control.check()
            } catch {
                await self.cleanupDowngradeADB(device:device,args:["shell","rm -f -- " + Input.remoteQuote(partial)])
                throw error
            }
            self.append("手机端大小和 MD5 校验通过：\(remote)")
            _ = try await self.execute("adb",["shell","cmd deviceidle whitelist +com.color.otaassistant && am set-inactive com.color.otaassistant false && cmd deviceidle whitelist +com.oplus.ota"],device:device)
            // Refresh signed metadata after a potentially long file transfer.
            let status = try await self.withDowngradePort(device:device) { port in
                let actual = try await self.readDowngradeInfo(port:port,serial:serial,device:device)
                guard actual == catalog.device else { throw InputError.invalid("推送后当前版本或设备身份变化，未提交安装请求。") }
                let latest = try await DowngradeClient().query(actual)
                let latestPackage = try latest.refreshedPackage(matching:package)
                try control.check(); self.activity = "等待手机端降级助手回应，已发出的请求无法撤回"
                return try await DowngradeAssistant.install(port:port,catalog:latest,package:latestPackage,remotePath:remote,control:control)
            }
            guard status == 0 else { throw InputError.invalid("降级助手 verifyResult=\(status)，未报告提交成功。包保留在 \(remote)，请核对手机状态。") }
            self.append("降级助手返回 verifyResult=0。请打开手机「设置 → 系统与更新 → 软件更新 → 本地安装」完成手机端操作；这不代表系统已完成降级。\n安装包：\(remote)")
        }
    }
    private func startDowngradeAssistant(device: Device, apk: URL?) async throws {
        if let apk {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-ota-apk-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:directory) }
            let control = workControl
            let staged = try await Task.detached {
                try DowngradeFile.apk(apk).stage(to:directory.appendingPathComponent("assistant.apk"),control:control)
            }.value
            try control.check()
            let installed = try await execute("adb",["install","-r",staged.path],device:device,timeout:600)
            guard installed.stdout.components(separatedBy:.newlines).contains(where: { $0.trimmingCharacters(in:.whitespacesAndNewlines) == "Success" }) else { throw InputError.invalid("APK 安装未返回 Success，未继续降级查询。") }
        }
        let installed = try await execute("adb",["shell","pm","path","com.color.otaassistant"],device:device)
        guard installed.stdout.components(separatedBy:.newlines).contains(where:{$0.hasPrefix("package:")}) else { throw InputError.invalid("未找到 com.color.otaassistant，请先下载并选择降级助手 APK。") }
        _ = try await execute("adb",["shell","am","broadcast","-a","oplus.intent.action.OTA_ASSISTANT_PC_TOOL_RECEIVER","-n","com.color.otaassistant/.OtaAssistantReceiver"],device:device)
        try workControl.check(); try await Task.sleep(nanoseconds:3_000_000_000); try workControl.check()
    }
    private func downgradeSerial(_ device: Device) async throws -> String {
        let result = try await execute("adb",["shell","getprop","ro.serialno"],device:device)
        let serial = result.stdout.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !serial.isEmpty, serial.utf8.count <= 256, !serial.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw InputError.invalid("设备未返回有效 ro.serialno。") }
        return serial
    }
    private func readDowngradeInfo(port: UInt16, serial: String, device: Device) async throws -> DowngradeDeviceInfo {
        let control = workControl
        for attempt in 1...3 {
            do { return try await DowngradeAssistant.deviceInfo(port:port,serial:serial,control:control) }
            catch {
                try control.check()
                if attempt == 3 { throw error }
                append("降级助手暂未就绪，准备第 \(attempt+1) 次连接。")
                try await Task.sleep(nanoseconds:5_000_000_000); try control.check()
                _ = try await execute("adb",["shell","am","broadcast","-a","oplus.intent.action.OTA_ASSISTANT_PC_TOOL_RECEIVER","-n","com.color.otaassistant/.OtaAssistantReceiver"],device:device)
                try await Task.sleep(nanoseconds:2_000_000_000)
            }
        }
        throw InputError.invalid("降级助手未就绪。")
    }
    private func withDowngradePort<T>(device: Device, _ operation: (UInt16) async throws -> T) async throws -> T {
        try workControl.check()
        // Finish this short allocation even when Stop is pressed, so the exact
        // port can be removed. Never remove someone else's fixed port.
        guard let adb = locator.locate("adb") else { throw InputError.invalid("找不到 adb。") }
        let environment = locator.environment
        let result = try await Task.detached {
            try await CommandRunner().run(executable:adb,arguments:["-s",device.serial,"forward","tcp:0","tcp:9527"],environment:environment,timeout:8)
        }.value
        guard result.succeeded else { throw InputError.invalid("ADB 未能创建降级助手转发。") }
        guard let port = UInt16(result.stdout.trimmingCharacters(in:.whitespacesAndNewlines)), port > 0 else { throw InputError.invalid("ADB 未返回动态分配的降级助手端口。") }
        do {
            try workControl.check()
            let value = try await operation(port)
            await cleanupDowngradeADB(device:device,args:["forward","--remove","tcp:\(port)"])
            return value
        } catch {
            await cleanupDowngradeADB(device:device,args:["forward","--remove","tcp:\(port)"])
            throw error
        }
    }
    // Cleanup must still run after the normal command runner has been cancelled.
    private func cleanupDowngradeADB(device: Device, args: [String]) async {
        guard let adb = locator.locate("adb") else { return }
        let environment = locator.environment
        do {
            let result = try await Task.detached {
                try await CommandRunner().run(executable:adb,arguments:["-s",device.serial] + args,environment:environment,timeout:8)
            }.value
            if !result.succeeded { append("降级助手临时转发 / 片段清理未成功，请在设备重连后检查。") }
        } catch { append("降级助手临时转发 / 片段清理未完成。") }
    }
}
