import Foundation

public struct FastbootPartitionCatalog: Sendable {
    public let sizes: [String: UInt64]
    public var names: Set<String> { Set(sizes.keys) }
    public static func parse(_ text: String) throws -> FastbootPartitionCatalog {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw InputError.invalid("设备分区响应过大。") }
        var sizes: [String: UInt64] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "partition-size:") else { continue }
            let fields = line[marker.upperBound...].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count == 2 else { throw InputError.invalid("设备分区容量字段不完整。") }
            let name = try Input.partition(fields[0]), hex = fields[1].lowercased()
            guard name.utf8.count <= 128, let size = UInt64(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16), size <= UInt64(Int64.max), sizes[name] == nil || sizes[name] == size else { throw InputError.invalid("设备分区容量冲突或溢出。") }
            sizes[name] = size
        }
        guard !sizes.isEmpty, sizes.count <= 16384 else { throw InputError.invalid("设备没有返回可用分区目录。") }
        return FastbootPartitionCatalog(sizes: sizes)
    }
}

public struct OujiaImage: Identifiable, Sendable {
    public let name: String
    public let relativePath: String
    public let byteCount: UInt64
    public var id: String { relativePath }
    public var baseName: String { PartitionCommands.withoutSlot(name) }
}

public struct OujiaPackage: Sendable {
    public let root: URL
    public let images: [OujiaImage]
    public static func open(_ folder: URL, control: WorkControl = WorkControl()) throws -> OujiaPackage {
        var images: [OujiaImage] = []
        let actual = folder.resolvingSymlinksInPath()
        for relative in ["", "images"] {
            let directory = relative.isEmpty ? folder : folder.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                try control.check()
                guard ["img","bin","mbn","elf"].contains(file.pathExtension.lowercased()), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let resolved = file.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(actual.path + "/") else { throw InputError.invalid("镜像位于包目录之外。") }
                let snapshot = try FileSnapshot(resolved), name = try Input.partition(file.deletingPathExtension().lastPathComponent)
                guard snapshot.size > 0 else { continue }
                images.append(OujiaImage(name: name, relativePath: relative.isEmpty ? file.lastPathComponent : relative + "/" + file.lastPathComponent, byteCount: snapshot.size))
            }
        }
        guard !images.isEmpty, images.count <= 16384 else { throw InputError.invalid("目录中未找到镜像，或镜像数量超过限制。") }
        return OujiaPackage(root: folder.standardizedFileURL, images: images.sorted { $0.relativePath < $1.relativePath })
    }
}

public enum OujiaPlatform: String, CaseIterable, Sendable { case qualcomm = "高通", mediaTek = "联发科" }
public enum OujiaMode: String, CaseIterable, Sendable { case standard = "标准线刷", rebuild = "强力 / 重建 Super", bothSlots = "AB 通刷", fastbootdOnly = "仅 FastbootD" }

public struct OujiaFlashConfiguration: Sendable {
    public var mode: OujiaMode = .standard
    public var platform: OujiaPlatform = .qualcomm
    public var targetSlot = "a"
    public var clearData = false
    public var reboot = false
    public var protectCalibration = true
    public init() {}
}

public enum OujiaFlashPlanner {
    public static let logical: Set<String> = ["system","odm","vendor","product","system_ext","system_dlkm","vendor_dlkm","odm_dlkm","my_bigball","my_carrier","my_company","my_engineering","my_heytap","my_manifest","my_preload","my_product","my_region","my_stock"]
    public static func detectPlatform(_ catalog: FastbootPartitionCatalog) throws -> OujiaPlatform {
        let bases = Set(catalog.names.map(PartitionCommands.withoutSlot)), mtk = bases.contains("lk"), qc = bases.contains("xbl")
        guard mtk != qc else { throw InputError.invalid("设备分区表未提供唯一 lk / xbl 平台特征，请先核对设备平台。") }
        return mtk ? .mediaTek : .qualcomm
    }

    public static func make(package: OujiaPackage, selected: Set<String>, catalog: FastbootPartitionCatalog,
                            currentSlot: String, userspace: Bool, configuration c: OujiaFlashConfiguration, control: WorkControl = WorkControl()) throws -> FlashPlan {
        try control.check()
        guard ["a","b"].contains(currentSlot), ["a","b"].contains(c.targetSlot) else { throw InputError.invalid("欧加线刷需要有效 A/B 槽位。") }
        guard try detectPlatform(catalog) == c.platform else { throw InputError.invalid("所选处理器平台与设备分区表不一致。") }
        if c.mode == .fastbootdOnly {
            guard userspace, c.platform == .qualcomm else { throw InputError.invalid("仅 FastbootD 模式需要设备已在 FastbootD，且仅适用于高通流程。") }
        }
        var images = package.images.filter { selected.contains($0.id) }
        if c.protectCalibration {
            images = images.filter { !["persist","persistbak","ocdt","fsg","fsc","modemst1","modemst2","oplusdycnvbk","oplusstanvbk"].contains($0.baseName) }
        }
        guard !images.isEmpty else { throw InputError.invalid("未选择有效镜像。") }
        if c.mode != .standard {
            for required in ["my_company","my_preload"] where !images.contains(where: { $0.baseName == required }) {
                let candidates = package.images.filter { $0.baseName == required }
                guard candidates.count == 1 else { throw InputError.invalid("此模式需要唯一 \(required) 镜像，请放入包目录并明确选择。") }
                images.append(candidates[0])
            }
        }
        let grouped = Dictionary(grouping: images, by: \.baseName)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else { throw InputError.invalid("多个镜像将映射到同一目标分区，请每个分区只保留一个源镜像。") }
        let hasLk = images.contains { $0.baseName == "lk" }, hasXbl = images.contains { $0.baseName == "xbl" }
        if (c.platform == .qualcomm && hasLk && !hasXbl) || (c.platform == .mediaTek && hasXbl && !hasLk) { throw InputError.invalid("包中 lk / xbl 镜像与设备处理器不匹配。") }
        // Image suffixes describe source names; Windows selects targets using
        // the workflow's slot, rather than taking the file's suffix literally.
        let sorted = images.sorted { $0.byteCount == $1.byteCount ? $0.relativePath < $1.relativePath : $0.byteCount < $1.byteCount }
        let target = c.mode == .rebuild ? "a" : c.mode == .standard ? currentSlot : c.targetSlot
        var steps: [FlashStep] = []
        if userspace { steps.append(FlashStep(.requireFastbootd)) }
        else { steps.append(FlashStep(.reboot, target: "fastboot")) }
        func isSlotless(_ base: String) -> Bool { catalog.names.contains(base) && !catalog.names.contains(base + "_a") && !catalog.names.contains(base + "_b") }
        func resolve(_ image: OujiaImage, slot: String, rebuilding: Bool = false) throws -> String {
            let base = image.baseName, slotted = base + "_" + slot
            if catalog.names.contains(slotted) { return slotted }
            if isSlotless(base) { return base }
            if rebuilding && logical.contains(base) { return slotted }
            if base == "modem" && c.platform == .qualcomm { return slotted }
            throw InputError.invalid("设备分区表找不到 \(slotted) 或 \(base)，不能猜测目标。")
        }
        func flash(_ image: OujiaImage, slot: String, rebuilding: Bool = false) throws {
            try control.check()
            steps.append(FlashStep(.flash, target: try resolve(image, slot: slot, rebuilding: rebuilding), image: image.relativePath, exactTarget: true))
        }
        func cleanupCow() { steps.append(FlashStep(.cleanupCow)) }
        func rebuildLogical() throws {
            let selectedLogical = sorted.filter { logical.contains($0.baseName) }
            for image in selectedLogical {
                try control.check()
                if isSlotless(image.baseName) { steps.append(FlashStep(.deleteLogical, target: image.baseName, allowMissing: true)) }
                else { for slot in ["a","b"] { steps.append(FlashStep(.deleteLogical, target: image.baseName + "_" + slot, allowMissing: true)) } }
            }
            for image in selectedLogical {
                try control.check()
                let name = try resolve(image, slot: target, rebuilding: true)
                let source = try FlashPlan.create(root: package.root, steps: [FlashStep(.flash, target: name, image: image.relativePath)])
                let input = try PartitionImageInput.open(source.imageURL(image.relativePath), for: DevicePartition(name: name, size: UInt64(Int64.max)), control: control)
                guard input.expandedSize <= UInt64(Int64.max) - 4095 else { throw InputError.invalid("逻辑分区大小溢出。") }
                steps.append(FlashStep(.createLogical, target: name, size: (input.expandedSize + 4095) / 4096 * 4096))
            }
        }
        let nonLogical = sorted.filter { !logical.contains($0.baseName) && ($0.baseName != "modem" || isSlotless($0.baseName)) }
        let modem = sorted.filter { $0.baseName == "modem" && !isSlotless($0.baseName) }
        let extraNames: Set<String> = ["my_company","my_preload"]
        let extra = sorted.filter { extraNames.contains($0.baseName) }, main = sorted.filter { !extraNames.contains($0.baseName) }
        switch c.mode {
        case .standard:
            cleanupCow()
            for image in sorted where c.platform == .mediaTek || image.baseName != "modem" || isSlotless(image.baseName) { try flash(image, slot: target) }
        case .rebuild:
            if currentSlot == "b" {
                cleanupCow()
                for image in nonLogical { try flash(image, slot: "a") }
                steps.append(FlashStep(.setActive, target: "a")); try rebuildLogical()
            } else { try rebuildLogical(); cleanupCow() }
            for image in extra { try flash(image, slot: "a", rebuilding: true) }
            for image in main {
                if currentSlot == "b" {
                    if logical.contains(image.baseName) { try flash(image, slot: "a", rebuilding: true) }
                } else if c.platform == .mediaTek || image.baseName != "modem" || isSlotless(image.baseName) { try flash(image, slot: "a", rebuilding: true) }
            }
            if currentSlot == "b" && c.platform == .mediaTek { for image in modem { try flash(image, slot: "a") } }
        case .bothSlots:
            cleanupCow()
            for image in nonLogical {
                if isSlotless(image.baseName) { try flash(image, slot: target) }
                else { try flash(image, slot: "a"); try flash(image, slot: "b") }
            }
            if currentSlot != target { steps.append(FlashStep(.setActive, target: target)); try rebuildLogical() }
            for image in extra + main.filter({ logical.contains($0.baseName) }) { try flash(image, slot: target, rebuilding: currentSlot != target) }
        case .fastbootdOnly:
            if currentSlot != target { steps.append(FlashStep(.setActive, target: target)) }
            try rebuildLogical(); cleanupCow()
            for image in extra + main { try flash(image, slot: target, rebuilding: true) }
        }
        let deferredModem = modem.filter { !isSlotless($0.baseName) && c.mode != .fastbootdOnly && (c.platform == .qualcomm || c.mode == .bothSlots) }
        if !deferredModem.isEmpty {
            if c.platform == .qualcomm { steps.append(FlashStep(.reboot, target: "bootloader")) }
            for image in deferredModem { try flash(image, slot: "a"); try flash(image, slot: "b") }
            if c.platform == .qualcomm { steps.append(FlashStep(.reboot, target: "fastboot")) }
        }
        // All Windows full-package modes erase FRP in FastbootD, then perform
        // the user's clear-data / reboot choices. These remain visible steps.
        steps.append(FlashStep(.requireFastbootd)); steps.append(FlashStep(.erase, target: "frp", exactTarget: true))
        if c.clearData {
            steps += [FlashStep(.erase, target: "userdata", exactTarget: true),FlashStep(.erase, target: "metadata", exactTarget: true)]
            if c.platform == .qualcomm {
                steps.append(FlashStep(.wipeData))
                let misc = package.images.filter { $0.baseName == "misc" }
                guard misc.count <= 1 else { throw InputError.invalid("清数据收尾存在多个 misc 镜像，请保留唯一文件。") }
                if let misc = misc.first { steps.append(FlashStep(.flash, target: "misc", image: misc.relativePath, exactTarget: true)) }
            }
        }
        if c.reboot { steps.append(FlashStep(.reboot)) }
        return try FlashPlan.create(root: package.root, steps: steps)
    }
}
