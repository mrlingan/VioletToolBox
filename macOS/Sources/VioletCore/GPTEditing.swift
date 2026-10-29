import Foundation

public struct GPTSlotState: Sendable {
    public let slot: String?
    public let pairCount: Int
}

extension GPTDiskImage {
    private func slotPairs() throws -> [(base: String, a: GPTPartition, b: GPTPartition)] {
        var records: [String: [String: GPTPartition]] = [:]
        for partition in partitions {
            let name = partition.name.lowercased()
            guard name.hasSuffix("_a") || name.hasSuffix("_b") else { continue }
            let slot = String(name.suffix(1)), base = String(name.dropLast(2))
            guard !base.isEmpty, records[base]?[slot] == nil else { throw InputError.invalid("GPT 含重复槽位名称，不能推断活动槽。") }
            records[base, default: [:]][slot] = partition
        }
        return records.keys.sorted().compactMap { base in
            guard let a = records[base]?["a"], let b = records[base]?["b"] else { return nil }
            return (base, a, b)
        }
    }
    public func slotState() throws -> GPTSlotState {
        let pairs = try slotPairs()
        if let boot = pairs.first(where: { $0.base == "boot" }) {
            let a = (boot.a.attributes >> 48) & 15, b = (boot.b.attributes >> 48) & 15
            if a != b { return GPTSlotState(slot: a > b ? "a" : "b", pairCount: pairs.count) }
        }
        var slots: Set<String> = []
        for pair in pairs {
            let a = (pair.a.attributes >> 48) & 15, b = (pair.b.attributes >> 48) & 15
            if a != b { slots.insert(a > b ? "a" : "b") }
        }
        guard slots.count <= 1 else { throw InputError.invalid("GPT 中 A/B 槽位优先级冲突。") }
        return GPTSlotState(slot: slots.first, pairCount: pairs.count)
    }

    public func switchingSlot(to target: String) throws -> GPTDiskImage {
        guard ["a","b"].contains(target) else { throw InputError.invalid("目标槽位只能为 A 或 B。") }
        let state = try slotState(), pairs = try slotPairs()
        guard !pairs.isEmpty else { throw InputError.invalid("GPT 未包含完整 A/B 槽位对。") }
        if state.slot == target { return self }
        let offset = Int(header.entriesLBA * sectorSize)
        var entries = mainBytes.subdata(in: offset..<offset + Int(header.entryBytes))
        for pair in pairs {
            let a = Int((pair.a.index - 1) * header.entrySize), b = Int((pair.b.index - 1) * header.entrySize)
            // Preserve Windows behavior: exchange TYPE GUIDs, not unique GUIDs.
            let aType = entries.subdata(in: a..<a+16), bType = entries.subdata(in: b..<b+16)
            entries.replaceSubrange(a..<a+16, with: bType); entries.replaceSubrange(b..<b+16, with: aType)
            let active: UInt64 = pair.base == "boot" ? 0x103f000000000000 : 0x1004000000000000
            let other: UInt64 = pair.base == "boot" ? 0x103a000000000000 : 0
            try Self.store(target == "a" ? active : other, in: &entries, at: a + 48, bytes: 8)
            try Self.store(target == "b" ? active : other, in: &entries, at: b + 48, bytes: 8)
        }
        return try replacingEntries(entries)
    }

    private func replacingEntries(_ entries: Data) throws -> GPTDiskImage {
        guard entries.count == header.entryBytes else { throw InputError.invalid("GPT 条目长度变化。") }
        var main = mainBytes, backup = backupBytes
        let mainOffset = Int(header.entriesLBA * sectorSize), backupHeaderOffset = Int((backupHeader.currentLBA - backupHeader.entriesLBA) * sectorSize)
        main.replaceSubrange(mainOffset..<mainOffset+entries.count, with: entries)
        backup.replaceSubrange(0..<entries.count, with: entries)
        let entriesCRC = UInt64(GPTHeader.crc(entries))
        for region in [0,1] {
            var bytes = region == 0 ? main : backup
            let start = region == 0 ? Int(sectorSize) : backupHeaderOffset
            try Self.store(entriesCRC, in: &bytes, at: start + 88, bytes: 4)
            try Self.store(0, in: &bytes, at: start + 16, bytes: 4)
            let headerSize = Int(try bytes.integer(at: start + 12, bytes: 4))
            let crc = GPTHeader.crc(bytes.subdata(in: start..<start+headerSize))
            try Self.store(UInt64(crc), in: &bytes, at: start + 16, bytes: 4)
            if region == 0 { main = bytes } else { backup = bytes }
        }
        let primary = try GPTHeader.parse(main.subdata(in: Int(sectorSize)..<Int(sectorSize*2)), sectorSize: sectorSize, totalSectors: totalSectors, expectedLBA: 1)
        let secondary = try GPTHeader.parse(backup.subdata(in: backupHeaderOffset..<backupHeaderOffset+Int(sectorSize)), sectorSize: sectorSize, totalSectors: totalSectors, expectedLBA: backupHeader.currentLBA)
        let partitions = try primary.partitions(entries); _ = try secondary.partitions(entries)
        return GPTDiskImage(sectorSize: sectorSize, totalSectors: totalSectors, header: primary, backupHeader: secondary, partitions: partitions, mainBytes: main, backupBytes: backup)
    }
    private static func store(_ value: UInt64, in bytes: inout Data, at offset: Int, bytes count: Int) throws {
        guard [4,8].contains(count), offset >= 0, offset <= bytes.count, count <= bytes.count - offset else { throw InputError.invalid("GPT 字段写入越界。") }
        bytes.replaceSubrange(offset..<offset+count, with: (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// Open metadata exported by this application, without allocating a disk.
    public static func openMetadata(main mainURL: URL, backup backupURL: URL, sectorSize: UInt64, totalSectors: UInt64,
                                    control: WorkControl = WorkControl()) async throws -> GPTDiskImage {
        let mainFile = try FileSnapshot(mainURL), backupFile = try FileSnapshot(backupURL)
        guard [512,1024,2048,4096,8192,16384,32768,65536].contains(sectorSize),
              mainFile.size >= sectorSize * 2, mainFile.size <= 64 * 1024 * 1024,
              backupFile.size >= sectorSize * 2, backupFile.size <= 64 * 1024 * 1024,
              mainFile.size % sectorSize == 0, backupFile.size % sectorSize == 0 else { throw InputError.invalid("GPT 主备元数据长度或扇区大小无效。") }
        try control.check()
        let main = try Data(contentsOf: mainURL), backup = try Data(contentsOf: backupURL)
        let primary = try GPTHeader.parse(main.subdata(in: Int(sectorSize)..<Int(sectorSize * 2)), sectorSize: sectorSize, totalSectors: totalSectors, expectedLBA: 1)
        let backupSectors = backupFile.size / sectorSize
        guard primary.alternateLBA + 1 >= backupSectors else { throw InputError.invalid("GPT 备份文件范围越界。") }
        let backupStart = primary.alternateLBA + 1 - backupSectors
        guard mainFile.size / sectorSize <= primary.firstUsableLBA, backupStart > primary.lastUsableLBA else { throw InputError.invalid("元数据文件包含可用分区区域，请选择独立的 gpt_main / gpt_backup 文件。") }
        guard let image = try await GPTDiskImage.read(sectorSize: sectorSize, totalSectors: totalSectors, control: control, reader: { lba, count in
            let length = try checkedMultiply(count, sectorSize)
            if lba < mainFile.size / sectorSize, count <= mainFile.size / sectorSize - lba {
                let offset = Int(lba * sectorSize); return main.subdata(in: offset..<offset+Int(length))
            }
            guard lba >= backupStart, lba - backupStart < backupSectors, count <= backupSectors - (lba-backupStart) else { throw InputError.invalid("元数据文件未覆盖 GPT 声明的读取范围。") }
            let offset = Int((lba-backupStart) * sectorSize); return backup.subdata(in: offset..<offset+Int(length))
        }) else { throw InputError.invalid("主元数据中没有 GPT 签名。") }
        try control.check(); try mainFile.validate(); try backupFile.validate(); return image
    }
}

public enum GPTSlotTransaction {
    public static func current(_ volumes: [EDLVolume]) throws -> String {
        let slots = try Set(volumes.compactMap { try $0.gpt.slotState().slot })
        guard slots.count == 1, let slot = slots.first else { throw InputError.invalid("未找到唯一的跨 LUN 活动槽位。") }; return slot
    }
    public static func manifest(volumes: [EDLVolume], files: [UInt64: (main: URL, backup: URL)], bootable: UInt64?, to destination: URL) throws -> URL {
        guard !volumes.isEmpty, volumes.count <= 32, Set(volumes.map(\.id)).count == volumes.count, bootable == nil || bootable! <= 255 else { throw InputError.invalid("GPT 写入事务参数无效。") }
        let root = XMLElement(name: "violet_gpt_transaction")
        if let bootable { root.addAttribute(XMLNode.attribute(withName: "bootable", stringValue: String(bootable)) as! XMLNode) }
        for volume in volumes {
            guard let files = files[volume.id], files.main.deletingLastPathComponent() == destination.deletingLastPathComponent(), files.backup.deletingLastPathComponent() == destination.deletingLastPathComponent() else { throw InputError.invalid("GPT 事务镜像需位于同一私有目录。") }
            let node = XMLElement(name: "volume")
            let attrs = ["lun":String(volume.id),"sector":String(volume.geometry.sectorSize),"total":String(volume.geometry.totalSectors),"backup_start":String(volume.gpt.backupStartLBA),"main":files.main.lastPathComponent,"backup":files.backup.lastPathComponent]
            for key in attrs.keys.sorted() { node.addAttribute(XMLNode.attribute(withName: key, stringValue: attrs[key]!) as! XMLNode) }; root.addChild(node)
        }
        let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "UTF-8"
        let output = try AtomicOutput(destination); try output.handle.write(contentsOf: document.xmlData(options: .nodePrettyPrint)); return try output.commit()
    }
}
