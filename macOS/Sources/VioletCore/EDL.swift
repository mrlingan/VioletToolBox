import Foundation
import CryptoKit

public struct EDLUSBDevice: Identifiable, Sendable {
    public let vendor: UInt16
    public let product: UInt16
    public let serial: String
    public let ordinal: Int
    public var id: String { "\(vendor):\(product):\(serial):\(ordinal)" }
    public var label: String { String(format: "%04x:%04x", vendor, product) + " · " + (serial.isEmpty ? "无序列号" : serial) }
    public static func parse(_ text: String) throws -> [EDLUSBDevice] {
        guard text.utf8.count <= 1024 * 1024 else { throw InputError.invalid("EDL USB 列表过大。") }
        var result: [EDLUSBDevice] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2 else { continue }
            let ids = fields[0].split(separator: ":")
            guard ids.count == 2, let vendor = UInt16(ids[0], radix: 16), let product = UInt16(ids[1], radix: 16), vendor == 0x05c6 else { continue }
            let serial = fields[1]
            guard serial.utf8.count <= 256, !serial.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InputError.invalid("EDL 设备序列号无效。") }
            result.append(EDLUSBDevice(vendor: vendor, product: product, serial: serial, ordinal: result.count))
        }
        guard result.count <= 256 else { throw InputError.invalid("EDL 设备数超过限制。") }; return result
    }
}

public enum EDLMemory: String, CaseIterable, Sendable { case ufs, emmc }

public struct EDLLoader: Sendable {
    public struct Image: Sendable {
        public let id: UInt32
        public let source: URL
        public let size: UInt64
        public let sha256: String
        fileprivate let snapshot: FileSnapshot
    }
    public let sourceURL: URL
    public let images: [Image]
    private let manifest: FileSnapshot?
    private let archive: Bool
    public static func open(_ file: URL, control: WorkControl = WorkControl()) throws -> EDLLoader {
        let original = try FileSnapshot(file)
        var mapping: [(UInt32,URL)] = [], manifest: FileSnapshot?, archive = false
        if file.pathExtension.lowercased() == "xml" {
            guard original.size <= 1024 * 1024, let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw InputError.invalid("Sahara 配置需为 1 MiB 以内 UTF-8 XML。") }
            let root = try FirmwareXML.parse(text), directory = file.deletingLastPathComponent().resolvingSymlinksInPath()
            guard root.name.lowercased() == "sahara_config" else { throw InputError.invalid("Loader XML 缺少 sahara_config 根节点。") }
            for node in root.descendants where node.name.lowercased() == "image" {
                guard let id = node.attribute("image_id").flatMap(UInt32.init), id > 0, id < 128, let name = node.attribute("image_path") else { throw InputError.invalid("Sahara image_id 必须在 1–127，且需包含 image_path。") }
                let relative = try ArchivePaths.normalize(name), source = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
                guard source.path.hasPrefix(directory.path + "/") else { throw InputError.invalid("Sahara 镜像指向配置目录之外。") }
                mapping.append((id,source))
            }
            manifest = original
        } else {
            mapping = [(13,file.resolvingSymlinksInPath())]
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            archive = (try handle.read(upToCount: 6)) == Data("070701".utf8)
        }
        guard !mapping.isEmpty, mapping.count < 128, Set(mapping.map(\.0)).count == mapping.count else { throw InputError.invalid("Sahara 映射为空、重复或过多。") }
        var images: [Image] = [], total: UInt64 = 0
        for (id, source) in mapping {
            try control.check()
            let snapshot = try FileSnapshot(source); total = try checkedAdd(total, snapshot.size)
            guard snapshot.size > 0, total <= 512 * 1024 * 1024 else { throw InputError.invalid("Loader 为空或总量超过 512 MiB。") }
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            var hash = SHA256(), done: UInt64 = 0
            while done < snapshot.size {
                try control.check()
                let bytes = try handle.readExactly(offset: done, count: Int(min(1024 * 1024, snapshot.size - done)), fileSize: snapshot.size)
                hash.update(data: bytes); done += UInt64(bytes.count)
            }
            try snapshot.validate()
            images.append(Image(id: id, source: source, size: snapshot.size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), snapshot: snapshot))
        }
        try original.validate()
        return EDLLoader(sourceURL: file, images: images, manifest: manifest, archive: archive)
    }
    public func validate() throws { try manifest?.validate(); for image in images { try image.snapshot.validate() } }
    public func stage(in directory: URL, control: WorkControl) throws -> URL {
        try validate()
        let root = XMLElement(name: "sahara_config"), nodes = XMLElement(name: "images"); root.addChild(nodes)
        for image in images {
            try control.check()
            let name = "loader-\(image.id).bin", target = directory.appendingPathComponent(name)
            let output = try AtomicOutput(target), input = try FileHandle(forReadingFrom: image.source)
            defer { try? input.close() }
            var done: UInt64 = 0, hash = SHA256()
            while done < image.size {
                try control.check()
                let bytes = try input.readExactly(offset: done, count: Int(min(1024 * 1024, image.size - done)), fileSize: image.size)
                try output.handle.write(contentsOf: bytes); hash.update(data: bytes); done += UInt64(bytes.count)
            }
            try image.snapshot.validate()
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == image.sha256 else { throw InputError.invalid("Loader 摘要变化，请重新选择。") }
            _ = try output.commit()
            let node = XMLElement(name: "image")
            node.addAttribute(XMLNode.attribute(withName: "image_id", stringValue: String(image.id)) as! XMLNode)
            node.addAttribute(XMLNode.attribute(withName: "image_path", stringValue: name) as! XMLNode); nodes.addChild(node)
        }
        if archive { try control.check(); try validate(); return directory.appendingPathComponent("loader-13.bin") }
        let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "UTF-8"
        let target = directory.appendingPathComponent("sahara.xml"), output = try AtomicOutput(target)
        try output.handle.write(contentsOf: document.xmlData(options: .nodePrettyPrint)); try control.check(); try validate()
        return try output.commit()
    }
}

public struct EDLGeometry: Codable, Sendable, Identifiable, Equatable {
    public let lun: UInt64
    public let sectorSize: UInt64
    public let totalSectors: UInt64
    public var id: UInt64 { lun }
    public var byteCount: UInt64 { sectorSize * totalSectors }
    public func validate() throws {
        guard lun <= 255, [512,1024,2048,4096,8192,16384,32768,65536].contains(sectorSize), totalSectors >= 6,
              totalSectors <= UInt64(Int64.max) / sectorSize else { throw InputError.invalid("EDL 物理 LUN 几何信息无效。") }
    }
    public static func parse(_ text: String, serial: String, memory: EDLMemory) throws -> [EDLGeometry] {
        struct Result: Decodable { let serial: String; let memory: String; let luns: [EDLGeometry] }
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw InputError.invalid("EDL 几何响应过大。") }
        let lines = text.components(separatedBy: .newlines).filter { $0.hasPrefix("VIOLET_EDL_V1 ") }
        guard lines.count == 1 else { throw InputError.invalid("未收到唯一有效 EDL 几何响应。") }
        let result = try JSONDecoder().decode(Result.self, from: Data(lines[0].dropFirst(14).utf8))
        guard result.serial == serial, result.memory == memory.rawValue, !result.luns.isEmpty, result.luns.count <= 32,
              Set(result.luns.map(\.lun)).count == result.luns.count else { throw InputError.invalid("EDL 响应设备、存储类型或 LUN 目录不匹配。") }
        for geometry in result.luns { try geometry.validate() }; return result.luns.sorted { $0.lun < $1.lun }
    }
    public func arguments(start: UInt64, sectors: UInt64) throws -> [String] {
        try validate()
        guard sectors > 0, start < totalSectors, sectors <= totalSectors - start else { throw InputError.invalid("EDL 物理读取 / 写入范围越界。") }
        return [String(lun),String(sectorSize),String(start),String(sectors)]
    }
    public static func parseLUNs(_ text: String) throws -> [UInt64] {
        let fields = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let luns = fields.compactMap(UInt64.init)
        guard !luns.isEmpty, luns.count == fields.count, luns.count <= 32, Set(luns).count == luns.count, luns.allSatisfy({ $0 <= 255 }) else { throw InputError.invalid("LUN 需为逗号分隔的 0–255 整数，最多 32 项，不能重复。") }
        return luns
    }
}

public struct EDLContext: Sendable, Identifiable {
    public let id = UUID()
    public let device: EDLUSBDevice
    public let memory: EDLMemory
    public let loader: EDLLoader
    public init(device: EDLUSBDevice, memory: EDLMemory, loader: EDLLoader) throws {
        guard !device.serial.isEmpty else { throw InputError.invalid("设备无序列号，无法固定 EDL 操作目标。") }
        self.device = device; self.memory = memory; self.loader = loader
    }
    public func prefix(command: String, stagedLoader: URL) -> [String] { [command,device.serial,memory.rawValue,stagedLoader.path] }
}

public struct EDLVolume: Sendable, Identifiable {
    public let geometry: EDLGeometry
    public let gpt: GPTDiskImage
    public var id: UInt64 { geometry.lun }
    public init(geometry: EDLGeometry, gpt: GPTDiskImage) { self.geometry = geometry; self.gpt = gpt }
}

public struct EDLPartitionTarget: Sendable, Identifiable {
    public let geometry: EDLGeometry
    public let diskGUID: String
    public let partition: GPTPartition
    public var id: String { "\(geometry.lun):\(partition.uniqueGUID)" }
    public var byteCount: UInt64 { geometry.sectorSize * partition.sectorCount }
    public init(volume: EDLVolume, partition: GPTPartition) { geometry = volume.geometry; diskGUID = volume.gpt.header.diskGUID; self.partition = partition }
    public var backupFilename: String { "LUN\(geometry.lun)-\(partition.index)-" + partition.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_") + ".img" }
}
