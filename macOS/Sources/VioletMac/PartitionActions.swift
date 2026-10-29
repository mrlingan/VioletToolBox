import Foundation
import AppKit
import VioletCore

struct PartitionWriteItem: Sendable {
    let partition: DevicePartition
    let input: PartitionImageInput
}

extension AppModel {
    var partitionTableReady: Bool { (adbReady || fastbootReady) && partitionDeviceID == selectedID && !devicePartitions.isEmpty }

    func readDevicePartitionTable() {
        guard let device = selected, device.shellReady || device.transport == .fastboot else { return }
        perform("读取设备分区表") {
            let partitions: [DevicePartition]
            if device.transport == .adb {
                let result = try await self.execute("adb", RootModuleCommands.shell(PartitionCommands.listADB), device: device, timeout: 120, binary: true)
                partitions = try PartitionCommands.parseADB(result.stdout)
            } else {
                let result = try await self.execute("fastboot", ["getvar","all"], device: device, timeout: 30, binary: true)
                partitions = try PartitionCommands.parseFastboot(result.text)
            }
            try self.workControl.check()
            guard self.selectedID == device.id else { return }
            self.partitionImages = [:]; self.devicePartitions = partitions; self.partitionDeviceID = device.id
            self.append("\(device.serial)：读取到 \(partitions.count) 个分区。")
        }
    }

    func choosePartitionImage(_ partition: DevicePartition) {
        guard partitionTableReady, let file = chooseFiles().first else { return }
        partitionImages[partition.id] = file
    }
    func matchRawProgramPartitionImages() {
        guard partitionTableReady, let device = selected else { return }
        let files = chooseFiles(extensions: ["xml"], multiple: true)
        guard !files.isEmpty else { return }
        let partitions = devicePartitions
        perform("匹配 RawProgram 分区镜像") {
            let control = self.workControl
            let imported = try await Task.detached { try RawProgramImages.open(files, control: control) }.value
            try control.check()
            guard self.selectedID == device.id, self.partitionDeviceID == device.id else { throw InputError.invalid("设备已变化，请重新读表。") }
            var mappings: [String: URL] = [:]
            for entry in imported.entries {
                guard let partition = partitions.first(where: { $0.name == entry.label }) else {
                    self.append("当前分区表中没有同名分区，未匹配：\(entry.label)"); continue
                }
                mappings[partition.id] = entry.imageURL
            }
            guard !mappings.isEmpty else { throw InputError.invalid("XML 中的完整镜像未能与当前设备分区表同名匹配。") }
            self.partitionImages.merge(mappings) { _, imported in imported }
            for reason in imported.skipped { self.append(reason) }
            self.append("已匹配 \(mappings.count) 个分区镜像；仅绑定文件，尚未写入设备。")
        }
    }

    func matchPartitionImages() {
        guard partitionTableReady, let folder = chooseFiles(directories: true).first else { return }
        do {
            let imageFolder = folder.appendingPathComponent("images")
            let directories = [folder] + (FileManager.default.fileExists(atPath: imageFolder.path) ? [imageFolder] : [])
            let files = try directories.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isRegularFileKey]) }
                .filter { ["img","bin","mbn","elf"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            var mapping: [String: URL] = [:]
            for partition in devicePartitions {
                let exact = files.filter { $0.deletingPathExtension().lastPathComponent == partition.name }
                let candidates = exact.isEmpty ? files.filter { $0.deletingPathExtension().lastPathComponent == PartitionCommands.withoutSlot(partition.name) } : exact
                guard candidates.count <= 1 else { throw InputError.invalid("\(partition.name) 匹配多个镜像，请逐行选择。") }
                mapping[partition.id] = candidates.first
            }
            partitionImages = mapping; append("已匹配 \(mapping.count) / \(devicePartitions.count) 个分区镜像。请核对槽位和文件。")
        } catch { self.error = error.localizedDescription }
    }

    private func selectedPartitions(_ ids: Set<String>, protect: Bool) throws -> [DevicePartition] {
        guard partitionTableReady, let device = selected else { throw InputError.invalid("请重新读取当前设备分区表。") }
        let records = devicePartitions.filter { ids.contains($0.id) }
        let allowed = records.filter { !protect || !PartitionCommands.protected($0, adb: device.transport == .adb) }
        // Explicit names are useful when protection filtered the user's selection.
        let protectedNames = records.filter { protect && PartitionCommands.protected($0, adb: device.transport == .adb) }.map(\.name)
        if !protectedNames.isEmpty { append("保护已启用，跳过：" + protectedNames.joined(separator: "、")) }
        guard !allowed.isEmpty else { throw InputError.invalid("未选择可操作分区，或所选分区均受保护。") }
        return allowed
    }

    private func validatePartitionTargets(_ partitions: [DevicePartition], device: Device) async throws {
        let current: [DevicePartition]
        if device.transport == .adb {
            let result = try await execute("adb", RootModuleCommands.shell(PartitionCommands.listADB), device: device, timeout: 120, binary: true)
            current = try PartitionCommands.parseADB(result.stdout)
        } else {
            let result = try await execute("fastboot", ["getvar","all"], device: device, timeout: 30, binary: true)
            current = try PartitionCommands.parseFastboot(result.text)
        }
        for partition in partitions {
            guard let actual = current.first(where: { $0.name == partition.name }), actual.size == partition.size, actual.blockPath == partition.blockPath else {
                throw InputError.invalid("分区 \(partition.name) 的路径或容量已变化，请重新读表。")
            }
        }
    }

    func backupDevicePartitions(_ ids: Set<String>, fileExtension: String = "img", generateXML: Bool = false) {
        guard partitionTableReady, let device = selected else { return }
        let partitions = devicePartitions.filter { ids.contains($0.id) }
        guard !partitions.isEmpty, ["img","bin"].contains(fileExtension), let folder = chooseFiles(directories: true).first else { return }
        let target = folder.appendingPathComponent("VioletPartitions-" + UUID().uuidString.prefix(8))
        perform("回读设备分区") {
            try await self.validatePartitionTargets(partitions, device: device)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            self.append("回读目录：\(target.path)")
            var savedImages: [String: URL] = [:]
            for partition in partitions {
                try self.workControl.check()
                let output = target.appendingPathComponent(partition.name + "." + fileExtension)
                if device.transport == .adb {
                    _ = try await self.executeStream(PartitionCommands.readRaw(partition), device: device, to: output, expectedSize: partition.size)
                } else {
                    // fetch is device-dependent; a failed fetch never commits a file.
                    let temporary = try ExternalToolOutput(output)
                    _ = try await self.execute("fastboot", ["fetch",partition.name,temporary.url.path], device: device, timeout: 3600)
                    try temporary.commit(expectedSize: partition.size)
                }
                savedImages[partition.name] = output
            }
            if generateXML {
                guard device.transport == .adb else { throw InputError.invalid("镜像回读已完成；生成物理还原 XML 需要 ADB Root 读取 GPT。") }
                try await self.saveDeviceGPT(to: target, device: device, generateXML: true, savedImages: savedImages)
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func reviewPartitionWrites(_ ids: Set<String>, protect: Bool) {
        guard let device = selected else { return }
        do {
            let partitions = try selectedPartitions(ids, protect: protect), images = partitionImages
            perform("分析待写入镜像") {
                let control = self.workControl
                let items = try await Task.detached {
                    try partitions.map { partition -> PartitionWriteItem in
                        guard let source = images[partition.id] else { throw InputError.invalid("\(partition.name) 尚未选择镜像。") }
                        return PartitionWriteItem(partition: partition, input: try PartitionImageInput.open(source, for: partition, control: control))
                    }
                }.value
                try control.check()
                let details = items.map { "\($0.partition.name) ← \($0.input.sourceURL.path)\n\($0.input.isSparse ? "Sparse 展开后" : "Raw") \($0.input.expandedSize) / 分区 \($0.partition.size) bytes" }.joined(separator: "\n\n")
                self.pending = PendingOperation(title: "批量写入分区", detail: "设备：\(device.label)\n序列号：\(device.serial)\n模式：\(device.transport.rawValue)\n\n\(details)\n\n所选分区的数据将被覆盖，请确认固件适配并已备份。停止会等待当前设备命令结束，再停止后续步骤；已写入的数据不自动回滚。") {
                    self.writePartitionItems(items, device: device)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func writePartitionItems(_ items: [PartitionWriteItem], device: Device) {
        let remote = "/data/local/tmp/violet-partitions-" + UUID().uuidString
        let environment = locator.environment, adb = locator.locate("adb")
        perform("批量写入分区", stopAtBoundary: true) {
            let control = self.workControl
            for item in items { try item.input.validate() }
            try await self.validatePartitionTargets(items.map(\.partition), device: device)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-partitions-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            var stableInputs: [String: URL] = [:]
            if device.transport == .fastboot {
                stableInputs = try await Task.detached {
                    var copies: [String: URL] = [:]
                    for item in items {
                        copies[item.partition.id] = try item.input.copySource(to: directory.appendingPathComponent(UUID().uuidString + ".img"), control: control) { progress in
                            Task { @MainActor in self.reportWork(progress, control: control) }
                        }
                    }
                    return copies
                }.value
            }
            do {
                if device.transport == .adb { _ = try await self.execute("adb", ["shell","umask 077; mkdir " + Input.remoteQuote(remote)], device: device) }
                for (index, item) in items.enumerated() {
                    try control.check(); try item.input.validate()
                    self.append("写入 \(index + 1) / \(items.count)：\(item.partition.name)")
                    if device.transport == .adb {
                        let source = try await Task.detached {
                            try item.input.rawFile(in: directory, control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
                        }.value
                        let target = remote + "/\(index).img"
                        _ = try await self.execute("adb", ["push",source.path,target], device: device, timeout: 3600)
                        try control.check(); try item.input.validate()
                        _ = try await self.execute("adb", PartitionCommands.write(item.partition, remoteImage: target), device: device, timeout: 3600)
                    } else {
                        guard let input = stableInputs[item.partition.id] else { throw InputError.invalid("缺少已验证的镜像副本。") }
                        _ = try await self.execute("fastboot", ["flash",item.partition.name,input.path], device: device, timeout: 3600)
                    }
                    self.append("分区写入命令成功返回：\(item.partition.name)")
                    try control.check()
                }
            } catch {
                if device.transport == .adb, let adb { await self.cleanupPartitionWorkspace(remote, device: device, adb: adb, environment: environment) }
                throw error
            }
            if device.transport == .adb, let adb { await self.cleanupPartitionWorkspace(remote, device: device, adb: adb, environment: environment) }
        }
    }

    private func cleanupPartitionWorkspace(_ path: String, device: Device, adb: URL, environment: [String: String]) async {
        guard path.range(of: "^/data/local/tmp/violet-partitions-[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil else { return }
        do {
            let result = try await Task.detached {
                try await CommandRunner().run(executable: adb, arguments: ["-s",device.serial,"shell","rm -rf " + Input.remoteQuote(path)], environment: environment, timeout: 15)
            }.value
            if !result.succeeded { append("临时目录清理失败：\(path)") }
        } catch { append("临时目录清理失败：\(path) · \(error.localizedDescription)") }
    }

    func reviewPartitionErase(_ ids: Set<String>, protect: Bool) {
        guard let device = selected else { return }
        do {
            let partitions = try selectedPartitions(ids, protect: protect)
            pending = PendingOperation(title: "擦除分区", detail: "设备：\(device.label)\n序列号：\(device.serial)\n\n" + partitions.map { "\($0.name) · \($0.size) bytes" }.joined(separator: "\n") + "\n\n将清空所选分区，可能导致数据丢失或设备无法启动。停止等待当前命令完成，已擦除的数据无法回滚。") {
                self.perform("擦除分区", stopAtBoundary: true) {
                    try await self.validatePartitionTargets(partitions, device: device)
                    for partition in partitions {
                        try self.workControl.check()
                        let args = device.transport == .adb ? try PartitionCommands.erase(partition) : ["erase",partition.name]
                        _ = try await self.execute(device.transport.rawValue, args, device: device, timeout: 3600)
                        self.append("分区擦除命令成功返回：\(partition.name)"); try self.workControl.check()
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
