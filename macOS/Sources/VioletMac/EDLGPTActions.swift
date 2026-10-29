import Foundation
import AppKit
import VioletCore

extension AppModel {
    func importEDLGPTMetadata(lun: UInt64, main: URL?, backup: URL?) {
        guard let context = edlContext, let geometry = edlGeometries.first(where: { $0.lun == lun }), let main, let backup else { return }
        perform("分析待恢复 GPT") {
            let control = self.workControl
            let gpt = try await Task.detached {
                try await GPTDiskImage.openMetadata(main: main, backup: backup, sectorSize: geometry.sectorSize, totalSectors: geometry.totalSectors, control: control)
            }.value
            try control.check()
            guard self.edlContext?.id == context.id else { throw InputError.invalid("GPT 分析期间 EDL 会话变化。") }
            self.edlRestoreVolume = EDLVolume(geometry: geometry, gpt: gpt)
            self.append("GPT 主备元数据已分析：目标 LUN\(lun)，GUID \(gpt.header.diskGUID)，\(gpt.partitions.count) 个分区。尚未写入设备。")
        }
    }
    func inspectEDLSlot() {
        guard let context = edlContext else { return }
        let geometries = edlGeometries
        perform("读取 EDL 当前槽位") {
            self.edlSlot = ""; self.edlVolumes = []; self.edlImages = [:]
            let workspace = try await self.makeEDLWorkspace(context)
            defer { try? FileManager.default.removeItem(at: workspace.directory) }
            var volumes: [EDLVolume] = []
            for geometry in geometries {
                try self.workControl.check()
                if let volume = try await self.readEDLVolume(context, workspace: workspace, geometry: geometry) { volumes.append(volume) }
            }
            let slot = try GPTSlotTransaction.current(volumes)
            try self.workControl.check(); self.edlVolumes = volumes; self.edlImages = [:]; self.edlSlot = slot
            self.append("GPT 当前活动槽：\(slot.uppercased())。")
        }
    }
    func reviewEDLSlotChange(to target: String) {
        guard let context = edlContext, ["a","b"].contains(target), !edlVolumes.isEmpty else { return }
        do {
            let originals = edlVolumes, current = try GPTSlotTransaction.current(originals)
            guard current != target else { append("当前已经是 \(target.uppercased()) 槽。"); return }
            let changed = try originals.compactMap { volume -> EDLVolume? in
                guard try volume.gpt.slotState().pairCount > 0 else { return nil }
                return EDLVolume(geometry: volume.geometry, gpt: try volume.gpt.switchingSlot(to: target))
            }
            guard let folder = chooseFiles(directories: true).first else { return }
            let backup = folder.appendingPathComponent("VioletEDLSlotBackup-" + UUID().uuidString.prefix(8))
            let bootable: UInt64 = context.memory == .ufs ? (target == "a" ? 1 : 2) : 0
            let details = changed.map { "LUN\($0.id) · \((try? $0.gpt.slotState().pairCount) ?? 0) 个 A/B 对 · 主备 GPT" }.joined(separator: "\n")
            pending = PendingOperation(title: "通过 EDL 切换槽位", detail: "序列号：\(context.device.serial)\n\(current.uppercased()) → \(target.uppercased())\n\n\(details)\n\n沿用 Windows 的类型 GUID 交换和属性值规则；同时更新主备 GPT CRC。完成各 LUN 写入与回读核对后，设置启动 LUN value=\(bootable)。\n原表与被覆盖区域备份：\(backup.path)\n\n这是持久化分区表修改，错误固件可能无法启动。停止会等待整组 GPT 及启动 LUN 命令完成，避免在主备表之间中断；断电、设备拒绝和传输失败仍可能导致部分更改，需保留备份。") {
                self.writeEDLGPTTransaction(context: context, volumes: changed, originals: originals, bootable: bootable, backupDirectory: backup, resultingSlot: target)
            }
        } catch { self.error = error.localizedDescription }
    }
    func reviewEDLRestoreGPT() {
        guard let context = edlContext, let volume = edlRestoreVolume, let folder = chooseFiles(directories: true).first else { return }
        let originals = edlVolumes.filter { $0.id == volume.id }
        let backup = folder.appendingPathComponent("VioletEDLGPTBeforeRestore-" + UUID().uuidString.prefix(8))
        let old = originals.first?.gpt.header.diskGUID ?? "当前 GPT 未有有效读取记录，仅按物理 LUN 与容量核对"
        pending = PendingOperation(title: "恢复 EDL 主备 GPT", detail: "序列号：\(context.device.serial)\nLUN：\(volume.id)\n物理容量：\(volume.geometry.byteCount) bytes\n原 GUID：\(old)\n恢复 GUID：\(volume.gpt.header.diskGUID)\n恢复分区数：\(volume.gpt.partitions.count)\n\n主表：LBA 0 + \(UInt64(volume.gpt.mainBytes.count) / volume.geometry.sectorSize)\n备份：LBA \(volume.gpt.backupStartLBA) + \(UInt64(volume.gpt.backupBytes.count) / volume.geometry.sectorSize)\n原始覆盖区域备份：\(backup.path)\n\n将改变该 LUN 的全部分区寻址，可能使设备无法启动或无法访问数据。本操作不恢复分区内容、不调整磁盘尺寸、不自动重启。停止等待当前 GPT 事务完成。") {
            self.writeEDLGPTTransaction(context: context, volumes: [volume], originals: originals, bootable: nil, backupDirectory: backup, resultingSlot: nil)
        }
    }
    private func writeEDLGPTTransaction(context: EDLContext, volumes: [EDLVolume], originals: [EDLVolume], bootable: UInt64?, backupDirectory: URL, resultingSlot: String?) {
        perform("写入 EDL GPT 事务", stopAtBoundary: true) {
            guard self.edlContext?.id == context.id else { throw InputError.invalid("EDL 会话变化，请重新审阅。") }
            let workspace = try await self.makeEDLWorkspace(context)
            defer { try? FileManager.default.removeItem(at: workspace.directory) }
            let actual = try await self.probeEDL(context, workspace: workspace, luns: volumes.map(\.id))
            guard volumes.allSatisfy({ actual.contains($0.geometry) }) else { throw InputError.invalid("EDL 物理容量变化，请重新连接与审阅。") }
            for original in originals where volumes.contains(where: { $0.id == original.id }) {
                guard let fresh = try await self.readEDLVolume(context, workspace: workspace, geometry: original.geometry), fresh.gpt.mainBytes == original.gpt.mainBytes, fresh.gpt.backupBytes == original.gpt.backupBytes else { throw InputError.invalid("确认后的设备 GPT 已变化，未进行写入。") }
            }
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            for original in originals where volumes.contains(where: { $0.id == original.id }) {
                _ = try original.gpt.export(to: backupDirectory, prefix: "original_lun\(original.id)", lun: original.id, control: self.workControl)
            }
            var files: [UInt64: (main: URL, backup: URL)] = [:]
            for volume in volumes {
                let geometry = volume.geometry
                try await self.readEDLRange(context, workspace: workspace, geometry: geometry, start: 0, sectors: UInt64(volume.gpt.mainBytes.count) / geometry.sectorSize, destination: backupDirectory.appendingPathComponent("covered_main_lun\(volume.id).bin"))
                try await self.readEDLRange(context, workspace: workspace, geometry: geometry, start: volume.gpt.backupStartLBA, sectors: UInt64(volume.gpt.backupBytes.count) / geometry.sectorSize, destination: backupDirectory.appendingPathComponent("covered_backup_lun\(volume.id).bin"))
                let outputs = try volume.gpt.export(to: workspace.directory, prefix: "planned_lun\(volume.id)", lun: volume.id, control: self.workControl)
                files[volume.id] = (outputs[0], outputs[1])
            }
            let manifest = try GPTSlotTransaction.manifest(volumes: volumes, files: files, bootable: bootable, to: workspace.directory.appendingPathComponent("gpt-transaction.xml"))
            struct Record: Encodable { let lun: UInt64; let sectorSize: UInt64; let totalSectors: UInt64; let mainCount: UInt64; let backupStart: UInt64; let backupCount: UInt64; let newDiskGUID: String }
            struct Backup: Encodable { let serial: String; let memory: String; let bootable: UInt64?; let regions: [Record] }
            let record = Backup(serial: context.device.serial, memory: context.memory.rawValue, bootable: bootable, regions: volumes.map { Record(lun: $0.id, sectorSize: $0.geometry.sectorSize, totalSectors: $0.geometry.totalSectors, mainCount: UInt64($0.gpt.mainBytes.count) / $0.geometry.sectorSize, backupStart: $0.gpt.backupStartLBA, backupCount: UInt64($0.gpt.backupBytes.count) / $0.geometry.sectorSize, newDiskGUID: $0.gpt.header.diskGUID) })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(record).write(to: backupDirectory.appendingPathComponent("transaction-backup.json"), options: .withoutOverwriting)
            try self.workControl.check()
            self.append("原始 GPT 覆盖区域已备份到：\(backupDirectory.path)")
            self.edlVolumes = []; self.edlImages = [:]; self.edlSlot = ""
            _ = try await self.executeEDLTool("violet-edl", args: context.prefix(command: "gpt-write", stagedLoader: workspace.loader) + [manifest.path])
            if let resultingSlot { self.edlSlot = resultingSlot }
            self.append("GPT 写入与回读核对命令成功返回，请重新读取分区表。")
            NSWorkspace.shared.activateFileViewerSelecting([backupDirectory]); try self.workControl.check()
        }
    }
}
