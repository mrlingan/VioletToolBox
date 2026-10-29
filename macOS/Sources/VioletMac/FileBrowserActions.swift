import Foundation
import AppKit
import VioletCore

extension AppModel {
    func browseDeviceFiles(_ directory: String) {
        guard let device = selected, device.shellReady else { return }
        perform("浏览设备目录") { try await self.readDirectory(directory, device: device) }
    }
    private func readDirectory(_ directory: String, device: Device) async throws {
        let path = try RemoteFiles.path(directory)
        let result = try await execute("adb", ["shell", RemoteFiles.list(path)], device: device, timeout: 60, binary: true)
        let files = try RemoteFiles.parse(result.stdout, directory: path)
        guard selectedID == device.id else { return }
        remoteDirectory = path; remoteFiles = files
        append("目录 \(path)：\(files.count) 个项目。")
    }
    func editRemoteFile(name: String, folder: Bool, rename: RemoteFile? = nil) {
        guard let device = selected, device.shellReady else { return }
        let directory = remoteDirectory
        do {
            let script = try rename.map { try RemoteFiles.rename(source: $0.path, name: name) } ?? RemoteFiles.create(name: name, directory: directory, folder: folder)
            perform(rename == nil ? "新建项目" : "重命名项目") {
                _ = try await self.execute("adb", ["shell", script], device: device)
                try await self.readDirectory(directory, device: device)
            }
        } catch { self.error = error.localizedDescription }
    }
    func deleteRemoteFiles(_ files: [RemoteFile]) {
        guard let device = selected, device.shellReady, !files.isEmpty else { return }
        let directory = remoteDirectory
        do {
            let script = try RemoteFiles.delete(files.map(\.path))
            pending = PendingOperation(title: "删除设备文件", detail: "设备：\(device.label)\n序列号：\(device.serial)\n\n" + files.map(\.path).joined(separator: "\n") + "\n\n文件夹会递归删除，此操作不能撤销。") {
                self.perform("删除设备文件") {
                    _ = try await self.execute("adb", ["shell", script], device: device)
                    try await self.readDirectory(directory, device: device)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func receiveRemoteFiles(_ files: [RemoteFile]) {
        guard let device = selected, !files.isEmpty, let folder = chooseFiles(directories: true).first else { return }
        let target = folder.appendingPathComponent("VioletFiles-" + UUID().uuidString.prefix(8))
        perform("接收所选文件") {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for file in files {
                _ = try RemoteFiles.path(file.path, allowRoot: false)
                _ = try await self.execute("adb", ["pull", file.path, target.path], device: device, timeout: 3600)
            }
            self.append("接收目录：\(target.path)"); NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
    func installDeviceAPK(_ file: RemoteFile) {
        guard let device = selected, file.kind == .file, file.name.lowercased().hasSuffix(".apk") else { return }
        pending = PendingOperation(title: "安装设备上的 APK", detail: "设备：\(device.serial)\n文件：\(file.path)\n\n将以替换模式安装此 APK。") {
            self.perform("安装设备上的 APK") {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("VioletAPK-" + UUID().uuidString + ".apk")
                defer { try? FileManager.default.removeItem(at: temporary) }
                _ = try await self.execute("adb", ["pull", file.path, temporary.path], device: device, timeout: 600)
                _ = try await self.execute("adb", ["install", "-r", temporary.path], device: device, timeout: 600)
            }
        }
    }
}
