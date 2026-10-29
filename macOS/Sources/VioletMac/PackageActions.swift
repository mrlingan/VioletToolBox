import Foundation
import AppKit
import VioletCore

extension AppModel {
    func openFirmwarePackage() {
        guard let url = chooseFiles(extensions: ["ofp", "ops"]).first else { return }
        perform("分析 OFP / OPS") {
            let control = self.workControl
            let document = try await Task.detached(priority: .userInitiated) { try FirmwarePackage.open(url, control: control) }.value
            try control.check()
            self.firmwarePackage = document
            self.append("\(document.format.label)：\(document.entries.count) 个可提取文件")
        }
    }

    func extractFirmwarePackage(names: Set<String>) {
        guard let document = firmwarePackage, let folder = chooseFiles(directories: true).first else { return }
        let target = folder.appendingPathComponent("VioletFirmware-" + String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString.prefix(6), isDirectory: true)
        perform("解包 OFP / OPS") {
            let control = self.workControl
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            self.append("输出目录：\(target.path)")
            let files = try await Task.detached(priority: .userInitiated) {
                try document.extract(names: names, to: target, control: control) { progress in
                    Task { @MainActor in self.reportWork(progress, control: control) }
                }
            }.value
            self.append("已导出 \(files.count) 个文件（含包内配置文件）。")
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func openSparseImage() {
        guard let url = chooseFiles(extensions: ["img", "bin", "sparse"]).first else { return }
        perform("分析 Sparse 镜像") {
            let control = self.workControl
            let image = try await Task.detached(priority: .userInitiated) { try SparseImage.inspect(url, control: control) }.value
            try control.check()
            self.sparseImage = image
            self.append("Sparse：\(image.chunkCount) chunks，展开大小 \(image.expandedSize) bytes")
        }
    }

    func expandSparseImage() {
        guard let image = sparseImage, let target = saveURL(name: image.sourceURL.deletingPathExtension().lastPathComponent + ".raw.img") else { return }
        perform("展开 Sparse 镜像") {
            let control = self.workControl
            let file = try await Task.detached(priority: .userInitiated) {
                try image.expand(to: target, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
            }.value
            self.append("已保存 Raw 镜像：\(file.path)")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    func chooseSuperSegments() {
        let files = chooseFiles(multiple: true)
        guard !files.isEmpty else { return }
        perform("分析 Super 分段") {
            let result = try await Task.detached(priority: .userInitiated) { () -> ([URL], [SuperVariant]) in
                let variants = try SuperSegments.variants(for: files)
                return (variants.isEmpty ? try SuperSegments.sorted(files) : files, variants)
            }.value
            try self.workControl.check()
            self.superFiles = result.0; self.superVariants = result.1; self.superVariantID = ""
            self.append(result.1.isEmpty ? "已选择 \(result.0.count) 个连续分段。" : "从 ProFile.xml 识别出 \(result.1.count) 个分段分组，请选择同一版本。")
        }
    }

    var selectedSuperFiles: [URL] {
        superVariants.isEmpty ? superFiles : superVariants.first(where: { $0.id == superVariantID })?.segments ?? []
    }

    func mergeSuperSegments() {
        let files = selectedSuperFiles
        guard files.count >= 2, let target = saveURL(name: "super.img") else { return }
        perform("合并 Super 分段") {
            let control = self.workControl
            let file = try await Task.detached(priority: .userInitiated) {
                try SuperSegments.merge(files, to: target, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
            }.value
            self.append("已合并 \(files.count) 个分段：\(file.path)")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}
