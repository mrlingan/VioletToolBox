import Foundation
import AppKit
import VioletCore

extension AppModel {
    func reportWork(_ progress: WorkProgress, control: WorkControl) {
        guard busy, workControl === control, !control.isCancelled else { return }
        workProgress = progress; activity = progress.label
    }

    func openPayload() {
        guard let url = chooseFiles(extensions: ["bin", "zip"]).first else { return }
        let old = payload
        perform("分析 Payload") {
            let control = self.workControl
            let document = try await Task.detached(priority: .userInitiated) {
                try PayloadArchive.open(url, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
            }.value
            if control.isCancelled { document.cleanup(); throw CancellationError() }
            old?.cleanup()
            self.payload = document
            self.append("找到 \(document.partitions.count) 个分区，block_size = \(document.blockSize)")
        }
    }

    func extractPayload(names: Set<String>) {
        guard let document = payload, let folder = chooseFiles(directories: true).first else { return }
        let destination = folder.appendingPathComponent("VioletPayload-" + String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString.prefix(6), isDirectory: true)
        perform("提取 Payload 分区") {
            let control = self.workControl
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            self.append("输出目录：\(destination.path)")
            let files = try await Task.detached(priority: .userInitiated) {
                try document.extract(names: names, to: destination, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
            }.value
            self.append("已导出：" + files.map(\.lastPathComponent).joined(separator: ", "))
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func chooseDownloadDestination() {
        let suggested = (try? HTTPClient.httpURL(downloadSource))?.lastPathComponent
        if let url = saveURL(name: suggested?.isEmpty == false ? suggested! : "ROM.zip") { downloadDestination = url }
    }

    func startDownload() {
        do {
            let source = try HTTPClient.httpURL(downloadSource)
            guard let destination = downloadDestination else { throw InputError.invalid("请先选择保存位置。") }
            let headers = downloadHeaders
            perform("下载文件") {
                let control = self.workControl
                // Do not put signed URLs or request headers into the shared log.
                self.append("下载目标：\(destination.path)")
                let file = try await self.downloadService.download(from: source, to: destination, headers: headers, control: control) { progress in
                    Task { @MainActor in self.reportWork(progress, control: control) }
                }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } catch { self.error = error.localizedDescription }
    }

    var romClient: ROMClient {
        let configured = ProcessInfo.processInfo.environment["VIOLET_ROM_API_BASE"]
        return ROMClient(baseURL: configured.flatMap { try? HTTPClient.httpURL($0) } ?? URL(string: "https://violettool.top/rom-api")!)
    }

    func resetROM(from level: String) {
        romLinks = nil
        if level == "brand" { romSeries = []; romSelection.series = "" }
        if level == "brand" || level == "series" { romDevices = []; romSelection.device = "" }
        romVersions = []; romSelection.version = ""
    }

    func queryROM(_ kind: String) {
        let selection = romSelection, client = romClient
        perform("查询 ROM") {
            let items = try await client.list(kind, selection: selection)
            switch kind {
            case "series": self.romSeries = items
            case "devices": self.romDevices = items
            default: self.romVersions = items
            }
            self.append("ROM 查询返回 \(items.count) 项")
        }
    }

    func queryROMLinks() {
        let selection = romSelection, client = romClient
        perform("获取 ROM 地址") {
            self.romLinks = try await client.links(selection: selection)
            self.append("已获取 ROM 下载地址，请在 ROM 页面选择。")
        }
    }

    func useROMLink(_ item: ROMLink) {
        downloadSource = item.url.absoluteString
        downloadHeaders = romLinks?.headers ?? [:]
        downloadDestination = nil
        chooseDownloadDestination()
    }
}
