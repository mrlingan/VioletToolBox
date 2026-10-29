import Foundation
import AppKit
import VioletCore

extension AppModel {
    func openBootImage() {
        guard let source = chooseFiles(extensions: ["img", "bin"]).first else { return }
        perform("分析 Boot 镜像") {
            self.bootImage = nil
            let image = try await Task.detached { try BootImage.open(source) }.value
            try self.workControl.check(); self.bootImage = image
            self.append("Boot v\(image.version)，\(image.components.count) 个组件；页大小 \(image.pageSize)。")
        }
    }
    func exportBootImage() {
        guard let image = bootImage, let folder = chooseFiles(directories: true).first else { return }
        let target = folder.appendingPathComponent("VioletBoot-" + UUID().uuidString.prefix(8))
        perform("导出 Boot 组件") {
            let control = self.workControl
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let files = try await Task.detached {
                try image.export(to: target, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
            }.value
            self.append("已导出 \(files.count) 个文件：\(target.path)")
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
    func openAVBImage() {
        guard let source = chooseFiles(extensions: ["img", "bin"]).first else { return }
        perform("分析 AVB 镜像") {
            self.avbImage = nil; self.avbResult = ""; self.avbBindings = [:]
            let image = try await Task.detached { try AVBImage.open(source) }.value
            try self.workControl.check(); self.avbImage = image
            self.append("AVB algorithm \(image.algorithm)，rollback index \(image.rollbackIndex)，\(image.descriptorTags.count) 个描述符。")
        }
    }
    func chooseAVBBindings() {
        let files = chooseFiles(extensions: ["img", "bin"], multiple: true)
        guard !files.isEmpty else { return }
        var bindings: [String: URL] = [:]
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard bindings[name] == nil else { error = "分区文件名重复：\(name)"; return }
            bindings[name] = url
        }
        avbBindings = bindings; avbResult = ""
    }
    func verifyAVBImage() {
        guard let image = avbImage else { return }
        let bindings = avbBindings
        perform("校验 AVB") {
            self.avbResult = ""
            let control = self.workControl
            do {
                let result = try await Task.detached {
                    try image.verify(images: bindings, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
                }.value
                self.avbResult = result.description; self.append(result.description)
            } catch { self.avbResult = "未通过：" + error.localizedDescription; throw error }
        }
    }
    func signAVBCopy(source: URL, key: URL, partition: String, size: String, rollback: String) {
        guard let bytes = UInt64(size), let index = UInt64(rollback) else { error = "分区容量与 rollback index 必须是非负整数。"; return }
        guard let target = saveURL(name: source.deletingPathExtension().lastPathComponent + ".signed.img") else { return }
        perform("生成 AVB 签名副本") {
            let control = self.workControl
            let file = try await Task.detached {
                try AVBImage.signCopy(source: source, destination: target, privateKey: key, partition: partition, partitionSize: bytes, rollback: index, control: control) {
                    progress in Task { @MainActor in self.reportWork(progress, control: control) }
                }
            }.value
            self.append("AVB 签名副本已完成自校验：\(file.path)")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
    func chooseModulePackages() {
        let files = chooseFiles(extensions: ["zip"], multiple: true)
        guard !files.isEmpty else { return }
        perform("分析 Root 模块 ZIP") {
            let control = self.workControl
            let packages = try await Task.detached {
                try files.map { try ModulePackage.open($0, control: control) }
            }.value
            guard Set(packages.map(\.id)).count == packages.count else { throw InputError.invalid("所选 ZIP 包含重复模块 id。") }
            self.modulePackages = packages
            self.append("已读取 \(packages.count) 个模块的元数据和 SHA-256。")
        }
    }
    var selectedRootManager: RootManager? { rootManagers.first { $0.id == rootManagerID } }
    var rootReady: Bool { adbReady && rootDeviceID == selectedID && selectedRootManager != nil }
    func detectRootManagers() {
        guard let device = selected, device.shellReady else { return }
        perform("请求 Root 授权并检测管理器") {
            self.rootManagers = []; self.rootManagerID = ""; self.rootDeviceID = ""; self.installedModules = []
            let result = try await self.execute("adb", RootModuleCommands.shell(RootModuleCommands.probe), device: device, timeout: 60, binary: true)
            let managers = try RootModuleCommands.managers(result.stdout)
            guard !managers.isEmpty else { throw InputError.invalid("已取得 Root 权限，但未检测到受支持的 Magisk / KernelSU / APatch CLI。") }
            self.rootManagers = managers; self.rootDeviceID = device.id
            self.rootManagerID = managers.count == 1 ? managers[0].id : ""
            self.append("Root 管理器：" + managers.map { $0.id + " " + $0.version }.joined(separator: "；"))
        }
    }
    func refreshRootModules() {
        guard rootReady, let device = selected else { return }
        perform("读取 Root 模块列表") { try await self.readRootModules(device) }
    }
    private func readRootModules(_ device: Device) async throws {
        let result = try await execute("adb", RootModuleCommands.shell(RootModuleCommands.list), device: device, timeout: 60, binary: true)
        let modules = try RootModuleCommands.modules(result.stdout)
        if selectedID == device.id, rootDeviceID == device.id { installedModules = modules }
        append("设备 \(device.serial)：读取到 \(modules.count) 个已安装模块。")
    }
    func changeRootModule(_ module: InstalledModule, action: RootModuleCommands.Action) {
        guard rootReady, let device = selected else { return }
        do {
            let script = try RootModuleCommands.change(id: module.id, action: action, manager: selectedRootManager)
            pending = PendingOperation(title: action.rawValue + "模块", detail: "设备：\(device.label)\n序列号：\(device.serial)\n模块：\(module.properties.name)（\(module.id)）\n\n更改模块标记，重启后完全生效；标记卸载不会立即删除模块。") {
                self.perform(action.rawValue + "模块") {
                    _ = try await self.execute("adb", RootModuleCommands.shell(script), device: device, timeout: 30)
                    try await self.readRootModules(device)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func installRootModules() {
        guard rootReady, let device = selected, let manager = selectedRootManager, !modulePackages.isEmpty,
              let adb = locator.locate("adb") else { return }
        let packages = modulePackages, environment = locator.environment
        let details = packages.map { "\($0.properties.name) · \($0.id) · \($0.properties.version)\nSHA-256：\($0.sha256)" }.joined(separator: "\n\n")
        pending = PendingOperation(title: "安装 Root 模块", detail: "设备：\(device.label)\n序列号：\(device.serial)\n管理器：\(manager.id)\n\n\(details)\n\n模块安装脚本会以 Root 权限执行，请确认模块来源。按顺序安装，失败即停止；已安装模块不会自动回滚。取消 ADB 不保证设备端脚本立即退出。") {
            self.perform("批量安装 Root 模块") {
                let control = self.workControl
                let cleanupRunner = CommandRunner()
                try await RootModuleCommands.install(packages, manager: manager, control: control, execute: { args, timeout in
                    _ = try await self.execute("adb", args, device: device, timeout: timeout)
                }, cleanup: { args, timeout in
                    // A fresh, detached task can clean our UUID directory after the main task is cancelled.
                    let result = try await Task.detached {
                        try await cleanupRunner.run(executable: adb, arguments: ["-s", device.serial] + args, environment: environment, timeout: timeout)
                    }.value
                    guard result.succeeded else { throw InputError.invalid("临时模块目录清理失败。") }
                }, installed: { id in Task { @MainActor in self.append("模块安装命令已成功返回：\(id)；重启后生效。") } })
                try await self.readRootModules(device)
            }
        }
    }
}
