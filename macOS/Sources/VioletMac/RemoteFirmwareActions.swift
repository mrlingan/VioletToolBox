import Foundation
import AppKit
import VioletCore

extension AppModel {
    func openRemoteFirmware(_ value: String? = nil, headers suppliedHeaders: [String:String]? = nil) {
        do {
            let url = try HTTPClient.httpURL(value ?? remoteFirmwareSource)
            let headers = suppliedHeaders ?? remoteFirmwareHeaders
            remoteFirmwareSource = url.absoluteString; remoteFirmwareHeaders = headers
            perform("读取远程 OTA / ZIP") {
                self.remoteFirmware = nil
                let archive = try await RemoteFirmwareArchive.open(url,headers:headers,control:self.workControl)
                try self.workControl.check(); self.remoteFirmware = archive
                self.append("远程目录读取完成：\(archive.payload?.partitions.count ?? 0) 个 Payload 分区，\(archive.zip?.entries.count ?? 0) 个 ZIP 条目。")
                for diagnostic in archive.diagnostics { self.append(diagnostic) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func useRemoteROMLink(_ item: ROMLink) { openRemoteFirmware(item.url.absoluteString,headers:romLinks?.headers ?? [:]) }
    func extractRemoteFirmware(names: Set<String>, zipEntries: Bool) {
        guard let archive = remoteFirmware, let folder = chooseFiles(directories:true).first else { return }
        let destination = folder.appendingPathComponent((zipEntries ? "VioletRemoteZIP-" : "VioletRemotePayload-") + UUID().uuidString.prefix(8))
        perform(zipEntries ? "提取远程 ZIP 文件" : "提取远程 Payload 分区") {
            let control = self.workControl
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let report: @Sendable (WorkProgress)->Void = { progress in Task { @MainActor in self.reportWork(progress,control:control) } }
            let files: [URL]
            if zipEntries, let zip = archive.zip { files = try await zip.extract(names:names,to:destination,control:control,progress:report) }
            else if !zipEntries, let payload = archive.payload { files = try await payload.extract(names:names,to:destination,control:control,progress:report) }
            else { throw InputError.invalid("远程来源没有所选内容类型。") }
            try control.check()
            self.append("已提取 \(files.count) 个文件：\(destination.path)")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
    func saveRemoteVersionMetadata() {
        guard let version = remoteFirmware?.version else { return }
        saveFirmwareMetadata(version)
    }
    func saveFirmwareMetadata(_ version: FirmwareVersionDetails) {
        guard let url = saveURL(name:"metadata") else { return }
        perform("保存原始 OTA metadata") {
            try version.bytes.write(to:url,options:.withoutOverwriting)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    func openLocalFirmwareVersion() {
        guard let url = chooseFiles(extensions:["zip","ozip"]).first else { return }
        perform("读取本地 OTA 版本信息") {
            self.localFirmwareVersion = nil; self.localFirmwareVersionSource = ""
            let version = try await FirmwareVersionDetails.readLocal(url,control:self.workControl)
            try self.workControl.check(); self.localFirmwareVersion = version; self.localFirmwareVersionSource = url.path
            self.append("已读取本地 OTA metadata：\(url.lastPathComponent)")
        }
    }
    func readDowngradeVersion(_ package: DowngradePackage) {
        guard let catalog = downgradeCatalog, catalog.packages.contains(package) else { return }
        let catalogID = catalog.id
        perform("解析降级包云端版本") {
            self.downgradeVersion = nil; self.downgradeVersionPackage = nil
            let version = try await FirmwareVersionDetails.readRemote(package.url,control:self.workControl)
            try self.workControl.check()
            guard self.downgradeCatalog?.id == catalogID else { throw InputError.invalid("降级查询结果已变化。") }
            self.downgradeVersion = version; self.downgradeVersionPackage = package.id
            self.append("降级包 metadata 读取完成；详情见降级助手页面。")
        }
    }
}
