import Foundation
import AppKit
import VioletCore

extension AppModel {
    func openLocalGPT(sectorSize: UInt64) {
        guard let file = chooseFiles().first else { return }
        perform("分析磁盘 GPT") {
            self.localGPT = nil; self.localGPTURL = nil
            let control = self.workControl
            let image = try await Task.detached { try await GPTDiskImage.open(file, sectorSize: sectorSize, control: control) }.value
            try control.check(); self.localGPT = image; self.localGPTURL = file
            self.append("GPT：\(image.partitions.count) 个分区；\(image.sectorSize) bytes / sector；主备表 CRC32 与条目一致。")
            if let warning = image.warning { self.append(warning) }
        }
    }
    func exportLocalGPT() {
        guard let image = localGPT, let parent = chooseFiles(directories: true).first else { return }
        let target = parent.appendingPathComponent("VioletGPT-" + UUID().uuidString.prefix(8))
        perform("导出本地 GPT") {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let control = self.workControl
            let files = try await Task.detached { try image.export(to: target, prefix: "gpt", control: control) }.value
            self.append("已导出 \(files.count) 个文件：\(target.path)"); NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
    func backupDeviceGPT(generateXML: Bool) {
        guard let device = selected, device.shellReady, let parent = chooseFiles(directories: true).first else { return }
        let target = parent.appendingPathComponent("VioletGPT-" + UUID().uuidString.prefix(8))
        perform("备份设备 GPT") {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try await self.saveDeviceGPT(to: target, device: device, generateXML: generateXML)
        }
    }
    func saveDeviceGPT(to target: URL, device: Device, generateXML: Bool, savedImages: [String: URL] = [:]) async throws {
        let control = self.workControl
        let response = try await self.execute("adb", RootModuleCommands.shell(BlockGeometry.probe), device: device, timeout: 120, binary: true)
        let geometries = try BlockGeometry.parse(response.stdout)
        guard !geometries.isEmpty else { throw InputError.invalid("未发现 UFS / eMMC 物理块设备。") }
        self.append("GPT 备份目录：\(target.path)")
        var completed = 0, failures: [String] = [], luns: Set<UInt64> = [], duplicateLUN = false, xmlEntries: [RawProgramEntry] = []
        struct Record: Encodable {
            let block: String; let lun: UInt64; let sectorSize: UInt64; let totalSectors: UInt64
            let diskGUID: String; let files: [String]
        }
        struct Manifest: Encodable { let serial: String; let disks: [Record]; let images: [String: String] }
        var records: [Record] = []
        var partitionMaps: [RawProgram.PartitionMap] = []
        for (index, geometry) in geometries.enumerated() {
            try control.check()
            self.workProgress = WorkProgress(geometry.name, done: UInt64(index), total: UInt64(geometries.count))
            do {
                guard let image = try await GPTDiskImage.read(sectorSize: geometry.sectorSize, totalSectors: geometry.totalSectors, control: control, reader: { lba, sectors in
                    let result = try await self.execute("adb", geometry.readArguments(lba: lba, sectors: sectors), device: device, timeout: 120, binary: true, rawOutput: true)
                    return result.data
                }) else { self.append("\(geometry.name)：没有主 GPT 签名，已跳过。"); continue }
                let uniqueLUN = !luns.contains(geometry.lun)
                let files = try image.export(to: target, prefix: "gpt_" + geometry.name, lun: uniqueLUN ? geometry.lun : nil, control: control)
                luns.insert(geometry.lun)
                if !uniqueLUN { duplicateLUN = true; self.append("\(geometry.name)：LUN 编号重复，按块设备名保存。") }
                partitionMaps.append(.init(lun: geometry.lun, sectorSize: geometry.sectorSize, partitions: image.partitions))
                records.append(Record(block: geometry.name, lun: geometry.lun, sectorSize: geometry.sectorSize, totalSectors: geometry.totalSectors, diskGUID: image.header.diskGUID, files: files.map(\.lastPathComponent)))
                if uniqueLUN {
                    xmlEntries += [
                        try RawProgramEntry(filename: files[0].lastPathComponent, label: "PrimaryGPT", lun: geometry.lun, sectorSize: geometry.sectorSize, startSector: 0, sectorCount: UInt64(image.mainBytes.count) / geometry.sectorSize),
                        try RawProgramEntry(filename: files[1].lastPathComponent, label: "BackupGPT", lun: geometry.lun, sectorSize: geometry.sectorSize, startSector: image.backupStartLBA, sectorCount: UInt64(image.backupBytes.count) / geometry.sectorSize)
                    ]
                }
                if let warning = image.warning { self.append("\(geometry.name)：\(warning)") }
                self.append("\(geometry.name) / LUN \(geometry.lun)：主备 GPT 已校验并保存，\(image.partitions.count) 个分区。")
                completed += 1
            } catch {
                try control.check()
                failures.append(geometry.name + "：" + error.localizedDescription)
                self.append("GPT 检查失败：\(failures.last!)")
            }
        }
        guard completed > 0 else { throw InputError.invalid("没有有效 GPT 可备份。\n" + failures.joined(separator: "\n")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(Manifest(serial: device.serial, disks: records, images: savedImages.mapValues { $0.lastPathComponent })).write(to: target.appendingPathComponent("backup-manifest.json"), options: .withoutOverwriting)
        if generateXML {
            guard !duplicateLUN else { throw InputError.invalid("GPT 二进制备份已保存，但物理 LUN 编号重复，未生成 rawprogram XML。请先确认设备的存储映射。") }
            xmlEntries += try RawProgram.partitionEntries(images: savedImages, maps: partitionMaps)
            for lun in luns.sorted() { _ = try RawProgram.write(xmlEntries.filter { $0.lun == lun }, to: target.appendingPathComponent("rawprogram\(lun).xml")) }
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
        if !failures.isEmpty { throw InputError.invalid("已备份 \(completed) 个 GPT，但部分设备检查失败；已完成输出保留。\n" + failures.joined(separator: "\n")) }
        self.append("已备份 \(completed) 个物理块设备的主备 GPT。")
    }
}
