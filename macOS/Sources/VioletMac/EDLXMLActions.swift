import Foundation
import AppKit
import VioletCore

extension AppModel {
    func importEDLFlashPackage(includeDirectoryPatches: Bool) {
        let files = chooseFiles(extensions: ["xml"], multiple: true)
        guard !files.isEmpty else { return }
        perform("导入 EDL RawProgram / Patch") {
            let control = self.workControl
            let package = try await Task.detached { try EDLFlashPackage.open(files, includeDirectoryPatches: includeDirectoryPatches, control: control) }.value
            try control.check(); self.edlFlashPackage = package; self.edlFlashPackageRevision = UUID()
            self.append("已导入 \(package.steps.count) 条物理 XML 命令。")
            for reason in package.skipped { self.append(reason) }
        }
    }
    func reviewEDLFlashPackage(selected: Set<Int>, gptOnly: Bool, protect: Bool, protectData: Bool, activate: Bool, allowSecurity: Bool) {
        guard let context = edlContext, let package = edlFlashPackage else { return }
        let knownTargets = edlTargets
        perform("解析 EDL XML 物理范围") {
            var skipped: [String] = []
            let ids = Set(package.steps.filter { step in
                guard selected.contains(step.id), !gptOnly || step.isGPT || step.kind == .patch else { return false }
                let name = PartitionCommands.withoutSlot(step.displayLabel)
                let blocked = (protect && PartitionCommands.basebandNames.contains(name)) || (protectData && ["userdata","metadata"].contains(name))
                if blocked { skipped.append("保护跳过 LUN\(step.lun) / \(step.displayLabel)") }; return !blocked
            }.map(\.id))
            guard !ids.isEmpty else { throw InputError.invalid("未选择可执行 XML 命令，或均被保护选项排除。") }
            let workspace = try await self.makeEDLWorkspace(context)
            defer { try? FileManager.default.removeItem(at: workspace.directory) }
            let luns = Set(package.steps.filter { ids.contains($0.id) }.map(\.lun)).sorted()
            guard luns.count <= 32 else { throw InputError.invalid("一次任务最多访问 32 个 LUN。") }
            let geometries = try await self.probeEDL(context, workspace: workspace, luns: luns)
            let control = self.workControl
            var prepared = try await Task.detached { try package.prepare(geometries: geometries, selected: ids, control: control) }.value
            let gptRanges = prepared.filter { $0.step.isGPT && $0.step.kind == .program }
            if gptOnly {
                guard !gptRanges.isEmpty else { throw InputError.invalid("所选 XML 不含 GPT program 条目。") }
                prepared = prepared.filter { item in
                    if item.step.kind != .patch { return item.step.isGPT }
                    let start = item.start * item.geometry.sectorSize + item.step.byteOffset
                    let matches = gptRanges.contains { region in
                        let low = region.start * region.geometry.sectorSize, high = low + region.sectors * region.geometry.sectorSize
                        return region.step.lun == item.step.lun && start >= low && start < high && item.step.patchSize <= high - start
                    }
                    if !matches { skipped.append("GPT-only 跳过外部 Patch：\(item.step.origin) / LUN\(item.step.lun):\(item.start)") }; return matches
                }
            }
            prepared = prepared.filter { item in
                guard item.step.kind == .patch else { return true }
                let start = item.start * item.geometry.sectorSize + item.step.byteOffset, end = start + item.step.patchSize
                let protected = knownTargets.contains { target in
                    let name = PartitionCommands.withoutSlot(target.partition.name)
                    let blocked = (protect && PartitionCommands.basebandNames.contains(name)) || (protectData && ["userdata","metadata"].contains(name))
                    let low = target.partition.firstLBA * target.geometry.sectorSize, high = (target.partition.lastLBA + 1) * target.geometry.sectorSize
                    return blocked && target.geometry.lun == item.step.lun && start < high && end > low
                }
                if protected { skipped.append("保护已读 GPT 中的分区，跳过 Patch：LUN\(item.step.lun):\(item.start)") }; return !protected
            }
            guard !prepared.isEmpty else { throw InputError.invalid("保护 / GPT-only 筛选后没有任务。") }
            guard allowSecurity || !prepared.contains(where: { $0.step.kind == .program && $0.step.displayLabel.lowercased() == "secdata" }) else { throw InputError.invalid("secdata 可能触发不可逆更改，请取消选择或明确启用对应选项。") }
            for item in prepared where item.step.isGPT {
                guard item.sectors * item.geometry.sectorSize <= 64 * 1024 * 1024 else { throw InputError.invalid("GPT 条目超过元数据备份限制。") }
            }
            let programs = prepared.filter { $0.step.kind == .program && !$0.step.isGPT }
            let a = programs.filter { $0.step.displayLabel.lowercased().hasSuffix("_a") }.count, b = programs.filter { $0.step.displayLabel.lowercased().hasSuffix("_b") }.count
            let bootable: UInt64? = activate && !gptOnly && context.memory == .ufs && a != b ? (a > b ? 1 : 2) : nil
            guard let folder = self.chooseFiles(directories: true).first else { return }
            let backup = folder.appendingPathComponent("VioletEDLXMLBefore-" + UUID().uuidString.prefix(8))
            let tasks = prepared
            let details = tasks.enumerated().map { index, item in
                item.step.kind == .patch
                ? "\(index+1). PATCH LUN\(item.step.lun) / LBA \(item.start) + byte \(item.step.byteOffset)，\(item.step.patchSize) bytes ← \(item.patchValue)"
                : "\(index+1). \(item.step.kind.rawValue) LUN\(item.step.lun) / \(item.step.displayLabel)\nLBA \(item.start) + \(item.sectors) · \(item.geometry.sectorSize) bytes/sector\n\(item.step.source?.path ?? "设备擦除")\(item.step.sparse ? " · 保留 Sparse DONT_CARE" : "")"
            }.joined(separator: "\n\n")
            let bytes = tasks.reduce(UInt64(0)) { $0 + $1.stagedBytes }
            self.pending = PendingOperation(title: gptOnly ? "执行 XML GPT 条目" : "执行 EDL 物理整包", detail: "序列号：\(context.device.serial)\n存储：\(context.memory.rawValue)\n稳定副本约 \(bytes) bytes\n执行前备份 GPT / Patch 覆盖区域：\(backup.path)\n启动 LUN：\(bootable.map(String.init) ?? "不改变")\n\n\(skipped.joined(separator: "\n"))\n\n\(details)\n\n按实际物理地址覆盖或擦除设备数据，可能使设备无法启动。所有输入先复制；普通任务在当前镜像或 Patch 命令完成后停止，GPT-only 在整组元数据命令结束后停止。已完成操作不回滚，断电和传输失败可能留下部分更改。") {
                self.executeEDLXMLPackage(context: context, package: package, tasks: tasks, geometries: geometries, bootable: bootable, gptOnly: gptOnly, allowSecurity: allowSecurity, backup: backup)
            }
            for reason in skipped { self.append(reason) }
        }
    }
    private func executeEDLXMLPackage(context: EDLContext, package: EDLFlashPackage, tasks: [PreparedEDLXMLStep], geometries: [EDLGeometry], bootable: UInt64?, gptOnly: Bool, allowSecurity: Bool, backup: URL) {
        perform("执行 EDL XML", stopAtBoundary: true) {
            guard self.edlContext?.id == context.id else { throw InputError.invalid("EDL 会话已变化，请重新审阅。") }
            let workspace = try await self.makeEDLWorkspace(context)
            defer { try? FileManager.default.removeItem(at: workspace.directory) }
            let control = self.workControl
            // Stage every image before the first program/erase/patch command.
            let jobs = try await Task.detached {
                var jobs: [URL] = []
                let groups = gptOnly ? [tasks] : tasks.map { [$0] }
                for (index, group) in groups.enumerated() {
                    try control.check()
                    let directory = workspace.directory.appendingPathComponent("xml-job-\(index)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    jobs.append(try package.stage(group, in: directory, bootable: nil, allowSecurityPartition: allowSecurity, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } })
                }
                try package.validate(); return jobs
            }.value
            let actual = try await self.probeEDL(context, workspace: workspace, luns: geometries.map(\.id))
            guard actual == geometries else { throw InputError.invalid("XML 确认后物理几何变化，未开始写入。") }
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            for item in tasks where item.step.isGPT || item.step.kind == .patch {
                let geometry = item.geometry, start: UInt64, count: UInt64
                if item.step.kind == .patch {
                    start = item.start + item.step.byteOffset / geometry.sectorSize
                    count = (item.step.byteOffset % geometry.sectorSize + item.step.patchSize + geometry.sectorSize - 1) / geometry.sectorSize
                } else { start = item.start; count = item.sectors }
                try await self.readEDLRange(context, workspace: workspace, geometry: geometry, start: start, sectors: count, destination: backup.appendingPathComponent("before_step\(item.step.id)_lun\(geometry.lun)_lba\(start).bin"))
            }
            struct Record: Encodable { let id: Int; let kind: String; let label: String; let lun: UInt64; let sectorSize: UInt64; let start: UInt64; let sectors: UInt64; let byteOffset: UInt64; let patchSize: UInt64; let value: String }
            struct Manifest: Encodable { let serial: String; let memory: String; let bootable: UInt64?; let tasks: [Record] }
            let record = Manifest(serial: context.device.serial, memory: context.memory.rawValue, bootable: bootable, tasks: tasks.map { Record(id: $0.step.id, kind: $0.step.kind.rawValue, label: $0.step.displayLabel, lun: $0.step.lun, sectorSize: $0.geometry.sectorSize, start: $0.start, sectors: $0.sectors, byteOffset: $0.step.byteOffset, patchSize: $0.step.patchSize, value: $0.patchValue) })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(record).write(to: backup.appendingPathComponent("xml-before-manifest.json"), options: .withoutOverwriting)
            try control.check(); self.workProgress = nil; self.edlVolumes = []; self.edlImages = [:]; self.edlSlot = ""
            for (index, job) in jobs.enumerated() {
                try control.check(); self.activity = "EDL XML \(index+1) / \(jobs.count)"
                _ = try await self.executeEDLTool("violet-edl", args: context.prefix(command: "xml-flash", stagedLoader: workspace.loader) + [job.path]); try control.check()
            }
            if tasks.contains(where: { $0.step.isGPT }) {
                var volumes: [EDLVolume] = []
                let metadataLUNs = Set(tasks.filter { $0.step.isGPT }.map { $0.step.lun })
                do {
                    for geometry in geometries {
                        if let volume = try await self.readEDLVolume(context, workspace: workspace, geometry: geometry) { volumes.append(volume) }
                        else if metadataLUNs.contains(geometry.lun) { throw InputError.invalid("XML GPT 写入后 LUN\(geometry.lun) 未返回主表签名。") }
                    }
                } catch { self.edlContext = nil; self.edlLastFailure = "XML 写入后未完成 GPT 确认：" + error.localizedDescription; throw error }
                self.edlVolumes = volumes
            }
            if let bootable {
                _ = try await self.executeEDLTool("violet-edl", args: context.prefix(command: "bootable", stagedLoader: workspace.loader) + [String(bootable)]); try control.check()
            }
            self.append("XML 设备命令全部成功返回；执行前元数据备份：\(backup.path)")
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        }
    }
}
