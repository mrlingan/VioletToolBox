import Foundation
import AppKit
import VioletCore

struct PreparedFlashStep: Sendable {
    let step: FlashStep
    let partition: DevicePartition?
    let input: PartitionImageInput?
    let checkBeforeFirstWrite: Bool
    let logical: Bool
}

extension AppModel {
    func importFlashPlan(_ file: URL? = nil) {
        guard let file = file ?? chooseFiles().first else { return }
        perform("导入线刷脚本") {
            let plan = try await Task.detached { try FlashPlan.open(file) }.value
            self.rawProgramImages = nil
            self.flashPlan = plan
            self.append("导入 \(file.lastPathComponent)：\(plan.document.steps.count) 步，\(plan.issues.count) 条未支持语句。")
        }
    }
    func scanFlashDirectory(excludeSensitive: Bool) {
        guard let root = chooseFiles(directories: true).first else { return }
        perform("扫描镜像目录") {
            self.flashPlan = try await Task.detached { try FlashPlan.scan(root, excludeSensitive: excludeSensitive) }.value
            self.rawProgramImages = nil
            self.append("已按文件名排序生成草案，请核对刷写顺序、目标分区和设备机型。")
        }
    }
    func importRawProgramImages() {
        let files = chooseFiles(extensions: ["xml"], multiple: true)
        guard !files.isEmpty else { return }
        perform("导入 RawProgram 完整镜像") {
            let control = self.workControl
            let imported = try await Task.detached { try RawProgramImages.open(files, control: control) }.value
            self.flashPlan = try imported.flashPlan(); self.rawProgramImages = imported
            self.append("导入 RawProgram：\(imported.entries.count) 个完整分区镜像；跳过 \(imported.skipped.count) 项。")
            for reason in imported.skipped { self.append(reason) }
        }
    }
    func exportFlashPlan() {
        guard let plan = flashPlan, let target = saveURL(name: "flash.violet.json") else { return }
        do {
            try rawProgramImages?.validate()
            // The file contains package-relative paths; copying it elsewhere
            // without the images must not silently change its meaning.
            guard target.deletingLastPathComponent().standardizedFileURL == plan.root else { throw InputError.invalid("请将计划保存在镜像包目录：\(plan.root.path)") }
            _ = try plan.exportJSON(to: target); NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch { self.error = error.localizedDescription }
    }
    func exportFlashShell() {
        guard let plan = flashPlan, let target = saveURL(name: "flash.command") else { return }
        let rawProgram = rawProgramImages
        perform("生成 macOS 线刷脚本") {
            try rawProgram?.validate()
            let control = self.workControl
            _ = try await Task.detached { try plan.exportShell(to: target, control: control) }.value
            self.append("脚本已生成。运行方式：bash \(target.path) 设备序列号 --execute")
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
    func moveFlashStep(_ index: Int, direction: Int) {
        guard let plan = flashPlan, plan.document.steps.indices.contains(index), plan.document.steps.indices.contains(index + direction) else { return }
        do {
            var steps = plan.document.steps; steps.swapAt(index, index + direction)
            flashPlan = try plan.replacingSteps(steps)
        } catch { self.error = error.localizedDescription }
    }
    func removeFlashStep(_ index: Int) {
        guard let plan = flashPlan, plan.document.steps.indices.contains(index) else { return }
        do {
            var steps = plan.document.steps; steps.remove(at: index)
            flashPlan = try plan.replacingSteps(steps)
        } catch { self.error = error.localizedDescription }
    }
    func readFlashVariable(_ name: String, device: Device) async throws -> String {
        let result = try await execute("fastboot", ["getvar",name], device: device, timeout: 30, binary: true)
        return try FlashPlan.variable(name, from: result.text)
    }
    private func verifyFlashRequirements(_ plan: FlashPlan, device: Device) async throws {
        let product = plan.document.product == nil ? nil : try await readFlashVariable("product", device: device)
        let anti = plan.document.maximumAnti == nil ? nil : try await readFlashVariable("anti", device: device)
        try plan.checkRequirements(product: product, anti: anti)
    }
    private func flashCapacity(_ name: String, device: Device) async throws -> DevicePartition {
        let value = try await readFlashVariable("partition-size:" + name, device: device)
        let hex = value.lowercased()
        guard let size = UInt64(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16) else { throw InputError.invalid("\(name) 容量响应无效。") }
        return try DevicePartition(name: name, size: size)
    }
    private func prepareFlashPlan(_ plan: FlashPlan, device: Device) async throws -> [PreparedFlashStep] {
        try plan.validate(); try await verifyFlashRequirements(plan, device: device)
        var slot: String?, records: [PreparedFlashStep] = [], changedEnvironment = false
        var logicalSizes: [String: UInt64] = [:], removed: Set<String> = []
        let knownSlotless: Set<String> = ["super","userdata","metadata","persist","misc","frp","ocdt","crclist","sparsecrclist"]
        for step in plan.document.steps {
            try workControl.check()
            if step.operation == .setActive { slot = step.target }
            if step.operation == .reboot, ["bootloader","fastboot"].contains(step.target) { changedEnvironment = true }
            if step.operation == .createLogical || step.operation == .resizeLogical {
                logicalSizes[step.target] = step.size!; removed.remove(step.target)
            }
            if step.operation == .deleteLogical { removed.insert(step.target); logicalSizes.removeValue(forKey: step.target) }
            guard step.operation == .flash || step.operation == .erase else {
                records.append(PreparedFlashStep(step: step, partition: nil, input: nil, checkBeforeFirstWrite: false, logical: false)); continue
            }
            var target = step.target
            if step.exactTarget != true && !target.hasSuffix("_a") && !target.hasSuffix("_b") && !knownSlotless.contains(target) && logicalSizes[target] == nil {
                guard !changedEnvironment else { throw InputError.invalid("跨模式步骤的 \(target) 未声明槽位，请改为明确的 _a / _b 分区名。") }
                let hasSlot = try await readFlashVariable("has-slot:" + target, device: device)
                guard ["yes","no"].contains(hasSlot) else { throw InputError.invalid("\(target) 的槽位响应无效。") }
                if hasSlot == "yes" {
                    if slot == nil { slot = try await readFlashVariable("current-slot", device: device).trimmingCharacters(in: CharacterSet(charactersIn: "_")).lowercased() }
                    guard let slot, ["a","b"].contains(slot) else { throw InputError.invalid("设备未返回有效当前槽位。") }
                    target += "_" + slot
                }
            }
            guard !removed.contains(target) else { throw InputError.invalid("\(target) 已安排删除，必须先重建再刷写。") }
            let managed = logicalSizes[target] != nil
            var partition: DevicePartition?
            let checkBeforeFirstWrite = !changedEnvironment && !managed
            if checkBeforeFirstWrite { partition = try await flashCapacity(target, device: device) }
            else if let declaredSize = logicalSizes[target], declaredSize > 0 { partition = try DevicePartition(name: target, size: declaredSize) }
            let concrete = FlashStep(step.operation, target: target, image: step.image, options: step.options, exactTarget: true)
            let input: PartitionImageInput?
            if let image = step.image {
                let url = try plan.imageURL(image), control = workControl
                let bound: DevicePartition
                if let partition { bound = partition }
                else { bound = try DevicePartition(name: target, size: UInt64(Int64.max)) }
                input = try await Task.detached { try PartitionImageInput.open(url, for: bound, control: control) }.value
                if logicalSizes[target] == 0, let input {
                    let aligned = try checkedFlashAlignment(input.expandedSize)
                    records.append(PreparedFlashStep(step: FlashStep(.resizeLogical, target: target, size: aligned), partition: nil, input: nil, checkBeforeFirstWrite: false, logical: false))
                    logicalSizes[target] = aligned; partition = try DevicePartition(name: target, size: aligned)
                }
            } else { input = nil }
            records.append(PreparedFlashStep(step: concrete, partition: partition, input: input, checkBeforeFirstWrite: checkBeforeFirstWrite, logical: managed))
            if step.operation == .flash && target == "super" { changedEnvironment = true; logicalSizes = [:]; removed = [] }
        }
        return records
    }
    private func checkedFlashAlignment(_ bytes: UInt64) throws -> UInt64 {
        guard bytes > 0, bytes <= UInt64(Int64.max) - 4095 else { throw InputError.invalid("逻辑镜像大小溢出。") }
        return (bytes + 4095) / 4096 * 4096
    }
    private func requireFastbootd(_ device: Device) async throws {
        let mode = try await readFlashVariable("is-userspace", device: device)
        guard mode == "yes" else { throw InputError.invalid("逻辑分区操作需要 FastbootD，设备未返回 is-userspace: yes。") }
    }
    private func waitForFlashMode(_ target: String, device: Device) async throws {
        let expected = target == "fastboot" ? "yes" : "no", deadline = Date().addingTimeInterval(120)
        var matches = 0
        append("等待序列号 \(device.serial) 进入 \(target == "fastboot" ? "FastbootD" : "Bootloader")…")
        while Date() < deadline {
            try workControl.check()
            do {
                let result = try await execute("fastboot", ["getvar","is-userspace"], device: device, timeout: 4, binary: true)
                if try FlashPlan.variable("is-userspace", from: result.text) == expected { matches += 1 } else { matches = 0 }
                if matches >= 2 { return }
            } catch { try workControl.check(); matches = 0 }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw InputError.invalid("等待原序列号切换模式超时；后续命令已停止。")
    }
    func reviewFlashPlan() {
        guard let device = selected, device.transport == .fastboot, let plan = flashPlan else { return }
        let rawProgram = rawProgramImages
        perform("检查批量线刷计划") {
            try rawProgram?.validate()
            let records = try await self.prepareFlashPlan(plan, device: device)
            let steps = records.enumerated().map { index, item in
                "\(index+1). \(item.step.summary)" + (item.input.map { "\n   展开大小 \($0.expandedSize) bytes" } ?? "") + (item.partition == nil && item.input != nil ? "\n   目标容量在对应模式到达后、写入之前检查" : "")
            }.joined(separator: "\n")
            let hazards = records.contains { $0.step.operation == .lock } ? "\n包含 Bootloader 回锁：固件、分区或签名不匹配可能导致设备无法启动。" : ""
            self.pending = PendingOperation(title: "执行批量线刷", detail: "设备：\(device.label)\n序列号：\(device.serial)\n包目录：\(plan.root.path)\n机型检查：\(plan.document.product ?? "包未声明，请人工核对")\n防回滚上限：\(plan.document.maximumAnti.map(String.init) ?? "包未声明，请人工核对")\n\n\(steps)\n\n刷入与擦除会覆盖设备数据。\(hazards)\n停止会等待当前命令完成，随后停止后续步骤；已完成操作不会回滚。") {
                self.executeFlashPlan(plan, records: records, device: device, rawProgram: rawProgram)
            }
        }
    }
    private func executeFlashPlan(_ plan: FlashPlan, records: [PreparedFlashStep], device: Device, rawProgram: RawProgramImages?) {
        perform("执行批量线刷", stopAtBoundary: true) {
            try plan.validate(); try rawProgram?.validate()
            // All inputs must be checked and copied before the first destructive
            // operation; an image missing near the end cannot leave half a ROM.
            for item in records { try item.input?.validate() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-flash-plan-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let control = self.workControl
            let stable = try await Task.detached {
                var files: [String: URL] = [:]
                for record in records {
                    if let input = record.input, files[input.sourceURL.path] == nil {
                        files[input.sourceURL.path] = try input.copySource(to: directory.appendingPathComponent(UUID().uuidString + ".img"), control: control) { progress in Task { @MainActor in self.reportWork(progress, control: control) } }
                    }
                }
                return files
            }.value
            try plan.validate(); try rawProgram?.validate(); try control.check()
            self.workProgress = nil
            try await self.verifyFlashRequirements(plan, device: device)
            for record in records {
                if record.checkBeforeFirstWrite, let expected = record.partition {
                    let current = try await self.flashCapacity(expected.name, device: device)
                    guard current.size == expected.size else { throw InputError.invalid("\(expected.name) 容量变化，请重新审阅。") }
                }
            }
            for (index, item) in records.enumerated() {
                try control.check()
                self.activity = "批量线刷 \(index+1) / \(records.count)：\(item.step.summary)"
                if item.step.operation == .requireFastbootd { try await self.requireFastbootd(device); try control.check(); continue }
                if item.step.operation == .cleanupCow { try await self.cleanupFlashCow(device); try control.check(); continue }
                if [.createLogical,.deleteLogical,.resizeLogical,.snapshotCancel].contains(item.step.operation) { try await self.requireFastbootd(device) }
                if item.step.operation == .flash || item.step.operation == .erase {
                    if item.logical {
                        try await self.requireFastbootd(device)
                        guard try await self.readFlashVariable("is-logical:" + item.step.target, device: device) == "yes" else { throw InputError.invalid("\(item.step.target) 未被设备确认为逻辑分区。") }
                    }
                    let actual = try await self.flashCapacity(item.step.target, device: device)
                    if let expected = item.partition, expected.size != actual.size { throw InputError.invalid("\(actual.name) 容量与审阅计划不符，已停止。") }
                    if let input = item.input, input.expandedSize > actual.size { throw InputError.invalid("\(actual.name) 容量小于镜像展开大小，已停止。") }
                }
                self.append("批量线刷 \(index+1) / \(records.count)：\(item.step.summary)")
                let args = try item.step.arguments(imageURL: item.input.flatMap { stable[$0.sourceURL.path] })
                let result: CommandResult
                do { result = try await self.execute("fastboot", args, device: device, timeout: 3600) }
                catch {
                    if item.step.operation == .deleteLogical, item.step.allowMissing == true, self.logicalPartitionMissing(error.localizedDescription) {
                        self.append("逻辑分区已不存在：\(item.step.target)"); try control.check(); continue
                    }
                    throw error
                }
                // Some vendor clients emit FAILED while exiting zero.
                if result.text.range(of: #"(?im)^\s*(?:FAILED\b|fastboot: error:)"#, options: .regularExpression) != nil {
                    if item.step.operation == .deleteLogical, item.step.allowMissing == true, self.logicalPartitionMissing(result.text) { try control.check(); continue }
                    throw InputError.invalid("Fastboot 返回失败，后续步骤已停止。")
                }
                try control.check()
                if item.step.operation == .reboot, ["bootloader","fastboot"].contains(item.step.target) {
                    try await self.waitForFlashMode(item.step.target, device: device)
                    if let product = plan.document.product {
                        guard try await self.readFlashVariable("product", device: device) == product else { throw InputError.invalid("模式切换后的机型检查不符，已停止。") }
                    }
                }
            }
        }
    }
    private func logicalPartitionMissing(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["partition not found","partition does not exist","no such partition","unknown partition","partition doesn't exist"].contains { text.contains($0) }
    }
    private func cleanupFlashCow(_ device: Device) async throws {
        try await requireFastbootd(device)
        let result = try await execute("fastboot", ["getvar","all"], device: device, timeout: 30, binary: true)
        let catalog = try FastbootPartitionCatalog.parse(result.text)
        let names = catalog.names.filter { $0.lowercased().contains("cow") }.sorted()
        append("COW 清理：设备返回 \(names.count) 个候选分区。")
        for name in names {
            try workControl.check()
            guard try await readFlashVariable("is-logical:" + name, device: device) == "yes" else { throw InputError.invalid("\(name) 不是设备确认的逻辑分区，未删除。") }
            do {
                let result = try await execute("fastboot", ["delete-logical-partition",name], device: device, timeout: 60)
                if result.text.range(of: #"(?im)^\s*(?:FAILED\b|fastboot: error:)"#, options: .regularExpression) != nil, !logicalPartitionMissing(result.text) { throw InputError.invalid("COW 删除失败：\(name)") }
            } catch {
                guard logicalPartitionMissing(error.localizedDescription) else { throw error }
            }
        }
    }
}
