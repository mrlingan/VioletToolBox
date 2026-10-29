import Foundation
import VioletCore

extension AppModel {
    func batchAppCommand(_ packages: [String], prefix: [String], title: String, warning: String = "") {
        guard let device = selected, !packages.isEmpty else { return }
        do {
            let packages = try packages.map { try Input.package($0) }.sorted()
            let action = {
                self.perform(title) {
                    for package in packages {
                        let result = try await self.execute("adb", prefix + [package], device: device, timeout: 120)
                        if result.text.localizedCaseInsensitiveContains("failure") || result.text.localizedCaseInsensitiveContains("failed") {
                            throw InputError.invalid("应用操作失败：\(package)\n\(result.text.suffix(2000))")
                        }
                    }
                }
            }
            if warning.isEmpty { action() }
            else { pending = PendingOperation(title: title, detail: "设备：\(device.label)\n序列号：\(device.serial)\n\n" + packages.joined(separator: "\n") + "\n\n\(warning)\n失败或取消会停止后续应用，已完成步骤不自动回滚。", action: action) }
        } catch { self.error = error.localizedDescription }
    }
    func screenRotation(_ value: Int?) {
        let script: String
        if let value { script = "settings put system user_rotation \(value) && settings put system accelerometer_rotation 0" }
        else { script = "settings put system accelerometer_rotation 1" }
        command("更改屏幕旋转", args: ["shell", script])
    }
    func resetFastbootData() {
        guard let device = selected, fastbootReady else { return }
        pending = PendingOperation(title: "格式化设备（双清）", detail: "设备：\(device.label)\n序列号：\(device.serial)\n\n将依次擦除 cache、userdata。手机中的用户数据会被删除，请先备份。失败即停止；已擦除的数据不能恢复。") {
            self.perform("格式化设备") {
                for name in ["cache", "userdata"] { _ = try await self.execute("fastboot", ["erase", name], device: device) }
            }
        }
    }
}
