import Foundation
import AppKit
import VioletCore

struct EDLWorkspace: Sendable {
    let directory: URL
    let loader: URL
}
private struct EDLWriteItem: Sendable {
    let target: EDLPartitionTarget
    let input: PartitionImageInput
}

extension AppModel {
    var selectedEDLDevice: EDLUSBDevice? { edlDevices.first { $0.id == selectedEDLDeviceID } }
    var edlTargets: [EDLPartitionTarget] { edlVolumes.flatMap { volume in volume.gpt.partitions.map { EDLPartitionTarget(volume: volume, partition: $0) } } }
    func clearEDLContext() {
        edlContext = nil; edlGeometries = []; edlVolumes = []; edlImages = [:]
        edlSlot = ""; edlRestoreVolume = nil
    }
    func scanEDLDevices() {
        perform("扫描 EDL USB 设备") {
            let result = try await self.executeEDLTool("qdl", args: ["list"], timeout: 15)
            self.edlDevices = try EDLUSBDevice.parse(result.stdout)
            if let context = self.edlContext, self.edlDevices.filter({ $0.serial == context.device.serial }).count != 1 { self.clearEDLContext() }
            if self.selectedEDLDeviceID.isEmpty, self.edlDevices.count == 1 { self.selectedEDLDeviceID = self.edlDevices[0].id }
            self.append("EDL USB：\(self.edlDevices.count) 个设备；扫描不发送 Loader。")
        }
    }
    func chooseEDLLoader() {
        guard let file = chooseFiles().first else { return }
        perform("分析 EDL Loader") {
            let control = self.workControl
            let loader = try await Task.detached { try EDLLoader.open(file, control: control) }.value
            try control.check(); self.clearEDLContext(); self.edlLoader = loader
            self.append("Loader 分析完成：\(loader.images.count) 个镜像。尚未发送设备。")
        }
    }
    func readEDLChipInfo() {
        guard let device = selectedEDLDevice, !device.serial.isEmpty else { return }
        perform("读取 Sahara 芯片信息") {
            guard self.edlContext == nil else { throw InputError.invalid("芯片信息请在发送 Loader 之前读取。") }
            let result = try await self.executeEDLTool("qdl", args: ["chipinfo","--backend=usb","--serial=" + device.serial], timeout: 30)
            self.edlChipInfo = result.text
        }
    }
    func reviewEDLConnect(memory: EDLMemory, lunText: String) {
        guard let device = selectedEDLDevice, let loader = edlLoader else { return }
        do {
            let luns = try EDLGeometry.parseLUNs(lunText)
            guard edlDevices.filter({ $0.serial == device.serial }).count == 1 else { throw InputError.invalid("多个 EDL 设备序列号相同，请只保留要操作的一台。") }
            let context = try EDLContext(device: device, memory: memory, loader: loader)
            let images = loader.images.map { "ID \($0.id) · \($0.source.lastPathComponent)\n\($0.size) bytes\nSHA-256 \($0.sha256)" }.joined(separator: "\n\n")
            pending = PendingOperation(title: "发送 EDL Loader 并读取存储信息", detail: "USB：\(device.label)\n序列号：\(device.serial)\n存储：\(memory.rawValue)\n查询 LUN：\(luns.map(String.init).joined(separator: ","))\n\n\(images)\n\n将通过 Sahara 向设备 RAM 发送所选 Loader，然后配置通用 Firehose 并读取物理容量。此步骤不写入闪存、不执行 UFS provisioning。厂商强制认证或 VIP 设备可能拒绝通用流程，届时会显示错误。") {
                self.perform("建立通用 EDL 会话") {
                    let workspace = try await self.makeEDLWorkspace(context)
                    defer { try? FileManager.default.removeItem(at: workspace.directory) }
                    let geometries = try await self.probeEDL(context, workspace: workspace, luns: luns)
                    try self.workControl.check()
                    self.clearEDLContext(); self.edlContext = context; self.edlGeometries = geometries; self.edlLastFailure = ""
                    self.append("已读取 \(geometries.count) 个物理 LUN。Loader 留在设备 RAM，操作之间释放 USB 句柄。")
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func makeEDLWorkspace(_ context: EDLContext) async throws -> EDLWorkspace {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-edl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        do {
            let control = workControl
            let loader = try await Task.detached { try context.loader.stage(in: directory, control: control) }.value
            try control.check(); return EDLWorkspace(directory: directory, loader: loader)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func probeEDL(_ context: EDLContext, workspace: EDLWorkspace, luns: [UInt64]) async throws -> [EDLGeometry] {
        let result = try await executeEDLTool("violet-edl", args: context.prefix(command: "geometry", stagedLoader: workspace.loader) + luns.map(String.init), timeout: 120)
        return try EDLGeometry.parse(result.stdout, serial: context.device.serial, memory: context.memory)
    }
    func readEDLRange(_ context: EDLContext, workspace: EDLWorkspace, geometry: EDLGeometry,
                              start: UInt64, sectors: UInt64, destination: URL) async throws {
        let output = try ExternalToolOutput(destination)
        let args = context.prefix(command: "read", stagedLoader: workspace.loader) + (try geometry.arguments(start: start, sectors: sectors)) + [output.url.path]
        _ = try await executeEDLTool("violet-edl", args: args)
        try workControl.check(); try output.commit(expectedSize: geometry.sectorSize * sectors)
    }
    func readEDLVolume(_ context: EDLContext, workspace: EDLWorkspace, geometry: EDLGeometry) async throws -> EDLVolume? {
        let control = workControl
        let gpt = try await GPTDiskImage.read(sectorSize: geometry.sectorSize, totalSectors: geometry.totalSectors, control: control) { start, sectors in
            let file = workspace.directory.appendingPathComponent(UUID().uuidString + ".gpt")
            defer { try? FileManager.default.removeItem(at: file) }
            try await self.readEDLRange(context, workspace: workspace, geometry: geometry, start: start, sectors: sectors, destination: file)
            return try Data(contentsOf: file)
        }
        return gpt.map { EDLVolume(geometry: geometry, gpt: $0) }
    }
    func readEDLGPT() {
        guard let context = edlContext else { return }
        let geometries = edlGeometries
        perform("读取 EDL GPT") {
            self.edlVolumes = []; self.edlImages = [:]; self.edlSlot = ""
            let workspace = try await self.makeEDLWorkspace(context)
            defer { try? FileManager.default.removeItem(at: workspace.directory) }
            var volumes: [EDLVolume] = []
            for geometry in geometries {
                try self.workControl.check()
                if let volume = try await self.readEDLVolume(context, workspace: workspace, geometry: geometry) { volumes.append(volume) }
                else { self.append("LUN \(geometry.lun) 没有主 GPT 签名。") }
            }
            try self.workControl.check()
            guard self.edlContext?.id == context.id else { throw InputError.invalid("EDL 会话已变化。") }
            self.edlVolumes = volumes; self.edlImages = [:]
            self.append("GPT：\(volumes.count) 个 LUN，\(volumes.reduce(0) { $0 + $1.gpt.partitions.count }) 个分区。")
        }
    }
    private func validateEDLTargets(_ targets: [EDLPartitionTarget], context: EDLContext, workspace: EDLWorkspace) async throws {
        guard edlContext?.id == context.id else { throw InputError.invalid("EDL 会话记录已变化，请重新连接并读表。") }
        let groups = Dictionary(grouping: targets, by: { $0.geometry.lun })
        let actual = try await probeEDL(context, workspace: workspace, luns: groups.keys.sorted())
        for lun in groups.keys.sorted() {
            guard let records = groups[lun], let expected = records.first?.geometry, actual.contains(expected),
                  let volume = try await readEDLVolume(context, workspace: workspace, geometry: expected) else { throw invalidateEDL("LUN \(lun) 容量变化或 GPT 缺失。") }
            for target in records {
                guard volume.gpt.header.diskGUID == target.diskGUID,
                      let partition = volume.gpt.partitions.first(where: { $0.uniqueGUID == target.partition.uniqueGUID }),
                      partition.name == target.partition.name, partition.firstLBA == target.partition.firstLBA,
                      partition.lastLBA == target.partition.lastLBA else { throw invalidateEDL("EDL 分区映射变化：\(target.partition.name)，请重新连接并读表。") }
            }
        }
    }
    private func invalidateEDL(_ message: String) -> InputError {
        edlContext = nil; edlLastFailure = message; return InputError.invalid(message)
    }
    func chooseEDLPartitionImage(_ target: EDLPartitionTarget) {
        guard edlContext != nil, let file = chooseFiles().first else { return }; edlImages[target.id] = file
    }
    func backupEDLPartitions(_ ids: Set<String>) {
        guard let context = edlContext, let folder = chooseFiles(directories: true).first else { return }
        let targets = edlTargets.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let destination = folder.appendingPathComponent("VioletEDL-" + UUID().uuidString.prefix(8))
        perform("回读 EDL 分区") {
            let workspace = try await self.makeEDLWorkspace(context)
            defer { try? FileManager.default.removeItem(at: workspace.directory) }
            try await self.validateEDLTargets(targets, context: context, workspace: workspace)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            for target in targets {
                try self.workControl.check()
                self.activity = "回读 LUN\(target.geometry.lun) / \(target.partition.name)"
                try await self.readEDLRange(context, workspace: workspace, geometry: target.geometry, start: target.partition.firstLBA, sectors: target.partition.sectorCount, destination: destination.appendingPathComponent(target.backupFilename))
            }
            struct Record: Encodable { let filename: String; let lun: UInt64; let sectorSize: UInt64; let diskGUID: String; let partition: GPTPartition }
            struct Manifest: Encodable { let serial: String; let memory: String; let partitions: [Record] }
            let manifest = Manifest(serial: context.device.serial, memory: context.memory.rawValue, partitions: targets.map { Record(filename: $0.backupFilename, lun: $0.geometry.lun, sectorSize: $0.geometry.sectorSize, diskGUID: $0.diskGUID, partition: $0.partition) })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(manifest).write(to: destination.appendingPathComponent("backup-manifest.json"), options: .withoutOverwriting)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
    func exportEDLGPT() {
        guard edlContext != nil, !edlVolumes.isEmpty, let folder = chooseFiles(directories: true).first else { return }
        let volumes = edlVolumes, destination = folder.appendingPathComponent("VioletEDLGPT-" + UUID().uuidString.prefix(8))
        perform("导出已读取的 EDL GPT") {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let control = self.workControl
            _ = try await Task.detached {
                try volumes.flatMap { try $0.gpt.export(to: destination, prefix: "gpt_lun\($0.geometry.lun)", lun: $0.geometry.lun, control: control) }
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
    func reviewEDLWrites(_ ids: Set<String>, protect: Bool, protectData: Bool = false) {
        guard let context = edlContext else { return }
        let targets = edlTargets.filter { ids.contains($0.id) }, images = edlImages
        let allowed = targets.filter {
            let name = PartitionCommands.withoutSlot($0.partition.name)
            return (!protect || !PartitionCommands.basebandNames.contains(name)) && (!protectData || !["userdata","metadata"].contains(name))
        }
        let skipped = targets.filter { target in !allowed.contains(where: { $0.id == target.id }) }
        if !skipped.isEmpty { append("EDL 保护跳过：" + skipped.map { "LUN\($0.geometry.lun)/\($0.partition.name)" }.joined(separator: "、")) }
        guard !allowed.isEmpty else { error = "没有可写入分区，或选择全部受保护。"; return }
        perform("分析 EDL 待写镜像") {
            let control = self.workControl
            let items = try await Task.detached {
                try allowed.map { target -> EDLWriteItem in
                    guard let file = images[target.id] else { throw InputError.invalid("尚未选择 \(target.partition.name) 镜像。") }
                    return EDLWriteItem(target: target, input: try PartitionImageInput.open(file, for: DevicePartition(name: "edl_target", size: target.byteCount), control: control))
                }
            }.value
            try control.check()
            let details = items.map { "LUN \($0.target.geometry.lun) / \($0.target.partition.name)\nLBA \($0.target.partition.firstLBA) + \($0.target.partition.sectorCount)\n← \($0.input.sourceURL.path)\n展开大小 \($0.input.expandedSize) bytes" }.joined(separator: "\n\n")
            self.pending = PendingOperation(title: "通过 EDL 写入分区", detail: "序列号：\(context.device.serial)\n存储：\(context.memory.rawValue)\n\n\(details)\n\n会覆盖所列物理分区数据。确认后先复制 / 展开全部输入，再核对实际 LUN 几何、GPT GUID 和分区范围。停止会等待当前分区命令完成，已写入的数据不会回滚。") {
                self.perform("EDL 写入分区", stopAtBoundary: true) {
                    let workspace = try await self.makeEDLWorkspace(context)
                    defer { try? FileManager.default.removeItem(at: workspace.directory) }
                    let control = self.workControl
                    let stable = try await Task.detached {
                        var files: [String: URL] = [:]
                        for item in items {
                            try item.input.validate()
                            let file = item.input.isSparse ? try item.input.rawFile(in: workspace.directory, control: control) : try item.input.copySource(to: workspace.directory.appendingPathComponent(UUID().uuidString + ".img"), control: control)
                            files[item.target.id] = file
                        }
                        return files
                    }.value
                    try await self.validateEDLTargets(items.map(\.target), context: context, workspace: workspace)
                    for item in items {
                        try control.check()
                        guard let file = stable[item.target.id] else { throw InputError.invalid("缺少镜像稳定副本。") }
                        let geometry = item.target.geometry
                        let sectors = (item.input.expandedSize + geometry.sectorSize - 1) / geometry.sectorSize
                        guard sectors <= item.target.partition.sectorCount else { throw InputError.invalid("镜像末尾对齐后超出分区。") }
                        let args = context.prefix(command: "write", stagedLoader: workspace.loader) + (try geometry.arguments(start: item.target.partition.firstLBA, sectors: sectors)) + [file.path]
                        _ = try await self.executeEDLTool("violet-edl", args: args); try control.check()
                    }
                }
            }
        }
    }
    func reviewEDLErase(_ ids: Set<String>, protect: Bool, protectData: Bool = false) {
        guard let context = edlContext else { return }
        let candidates = edlTargets.filter { ids.contains($0.id) }
        let targets = candidates.filter {
            let name = PartitionCommands.withoutSlot($0.partition.name)
            return (!protect || !PartitionCommands.basebandNames.contains(name)) && (!protectData || !["userdata","metadata"].contains(name))
        }
        let skipped = candidates.filter { candidate in !targets.contains(where: { $0.id == candidate.id }) }
        if !skipped.isEmpty { append("EDL 保护跳过：" + skipped.map { "LUN\($0.geometry.lun)/\($0.partition.name)" }.joined(separator: "、")) }
        guard !targets.isEmpty else { error = "没有可擦除分区，或选择全部受保护。"; return }
        let details = targets.map { "LUN \($0.geometry.lun) / \($0.partition.name)：LBA \($0.partition.firstLBA) + \($0.partition.sectorCount)" }.joined(separator: "\n")
        pending = PendingOperation(title: "通过 EDL 擦除分区", detail: "序列号：\(context.device.serial)\n\n\(details)\n\n将永久清空这些分区，可能导致数据丢失或设备无法启动。已擦除的数据不能回滚。") {
            self.perform("EDL 擦除分区", stopAtBoundary: true) {
                let workspace = try await self.makeEDLWorkspace(context)
                defer { try? FileManager.default.removeItem(at: workspace.directory) }
                try await self.validateEDLTargets(targets, context: context, workspace: workspace)
                for target in targets {
                    try self.workControl.check()
                    let args = context.prefix(command: "erase", stagedLoader: workspace.loader) + (try target.geometry.arguments(start: target.partition.firstLBA, sectors: target.partition.sectorCount))
                    _ = try await self.executeEDLTool("violet-edl", args: args); try self.workControl.check()
                }
            }
        }
    }
    func reviewEDLReset() {
        guard let context = edlContext else { return }
        pending = PendingOperation(title: "重启 EDL 设备", detail: "序列号：\(context.device.serial)\n发送 Firehose power reset，设备会断开当前 USB 会话。") {
            self.perform("重启 EDL 设备") {
                let workspace = try await self.makeEDLWorkspace(context)
                defer { try? FileManager.default.removeItem(at: workspace.directory) }
                _ = try await self.executeEDLTool("violet-edl", args: context.prefix(command: "reset", stagedLoader: workspace.loader), timeout: 120)
                self.clearEDLContext()
            }
        }
    }
}
