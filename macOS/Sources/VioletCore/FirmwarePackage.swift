import Foundation
import CryptoKit

public struct FirmwareEntry: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let size: UInt64
    public var encrypted: Bool { if case .none = cipher { return false }; return decryptLength > 0 }
    let offset: UInt64
    let decryptLength: UInt64
    let cipher: FirmwareCipher
}

public struct FirmwarePackage: Sendable {
    public enum Format: Sendable {
        case ofpQualcomm, ofpMediaTek, opsMbox(Int)
        public var label: String {
            switch self {
            case .ofpQualcomm: return "高通 OFP"
            case .ofpMediaTek: return "联发科 OFP"
            case let .opsMbox(version): return "OnePlus OPS · MBox \(version)"
            }
        }
    }
    public let sourceURL: URL
    public let format: Format
    public let entries: [FirmwareEntry]
    public var fileSize: UInt64 { snapshot.size }
    private let snapshot: FileSnapshot
    private let metadata: Data
    private let metadataName: String

    public static func open(_ url: URL, control: WorkControl = WorkControl()) throws -> FirmwarePackage {
        try control.check()
        let snapshot = try FileSnapshot(url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.readExactly(offset: 0, count: 16, fileSize: snapshot.size)
        if url.pathExtension.lowercased() == "ops" { return try readOPS(snapshot, input: input, control: control) }
        if header.starts(with: [0x50, 0x4b]) { throw InputError.invalid("这是 ZIP 封装的 OFP，此版本仅支持传统高通 / 联发科 OFP。") }
        for table in OFPKeys.mediatek {
            try control.check()
            let (key, iv) = try derive(table)
            if try FirmwareDecryptor.decrypt(header, cipher: .aes(key: key, iv: iv)).starts(with: Data("MMM".utf8)) {
                return try readMTK(snapshot, input: input, key: key, iv: iv, control: control)
            }
        }
        return try readQC(snapshot, input: input, control: control)
    }

    private static func readOPS(_ snapshot: FileSnapshot, input: FileHandle, control: WorkControl) throws -> FirmwarePackage {
        guard snapshot.size >= 512 else { throw InputError.invalid("OPS 文件过小。") }
        let footer = try input.readExactly(offset: snapshot.size - 512, count: 512, fileSize: snapshot.size)
        let xmlSize = try footer.integer(at: 0x18, bytes: 4)
        guard xmlSize > 0, xmlSize <= 32 * 1024 * 1024 else { throw InputError.invalid("OPS settings.xml 长度无效。") }
        let encryptedLength = try checkedAdd(xmlSize, 512 - xmlSize % 512)
        guard encryptedLength <= snapshot.size - 512 else { throw InputError.invalid("OPS settings.xml 超出文件范围。") }
        let offset = snapshot.size - 512 - encryptedLength
        let encoded = try input.readExactly(offset: offset, count: Int(encryptedLength), fileSize: snapshot.size)
        for version in [5, 6, 4] {
            try control.check()
            let decoded = try FirmwareDecryptor.decrypt(encoded, cipher: .ops(version: version))
            guard let text = String(data: decoded.prefix(Int(xmlSize)), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\u{feff}")),
                  let root = try? FirmwareXML.parse(text) else { continue }
            var entries: [FirmwareEntry] = []
            for section in root.children {
                let name = section.name.uppercased()
                guard name == "SAHARA" || name == "UFS_PROVISION" || name.contains("PROGRAM") else { continue }
                for node in [section] + section.descendants {
                    guard let path = node.attribute("Path") ?? node.attribute("filename"), !path.isEmpty,
                          let sectors = node.number("FileOffsetInSrc"), let size = node.number("SizeInByteInSrc"), size > 0 else { continue }
                    let encrypted = name == "SAHARA"
                    entries.append(FirmwareEntry(path: path, size: size, offset: try checkedMultiply(sectors, 512),
                        decryptLength: encrypted ? size : 0, cipher: encrypted ? .ops(version: version) : .none))
                }
            }
            return try make(snapshot, format: .opsMbox(version), entries: entries, metadata: Data(text.utf8), name: "settings.xml", dataEnd: offset)
        }
        throw InputError.invalid("无法识别 OPS；目前支持旧版 MBox 4、5、6。")
    }

    private static func readMTK(_ snapshot: FileSnapshot, input: FileHandle, key: Data, iv: Data, control: WorkControl) throws -> FirmwarePackage {
        guard snapshot.size >= 108 else { throw InputError.invalid("联发科 OFP 文件过小。") }
        let header = try shuffle(input.readExactly(offset: snapshot.size - 108, count: 108, fileSize: snapshot.size))
        let count = try header.integer(at: 72, bytes: 2), tableSize = try checkedMultiply(count, 96)
        guard count > 0, tableSize <= snapshot.size - 108 else { throw InputError.invalid("联发科 OFP 文件表范围无效。") }
        let tableOffset = snapshot.size - 108 - tableSize
        let table = try shuffle(input.readExactly(offset: tableOffset, count: Int(tableSize), fileSize: snapshot.size))
        var entries: [FirmwareEntry] = []
        for index in 0..<Int(count) {
            try control.check()
            let start = index * 96
            let size = try table.integer(at: start + 40, bytes: 8)
            guard size > 0 else { continue }
            let rawName = table.subdata(in: (start + 56)..<(start + 88)).prefix { $0 != 0 }
            guard let name = String(data: rawName, encoding: .utf8) else { throw InputError.invalid("OFP 文件名编码无效。") }
            entries.append(FirmwareEntry(path: name, size: size, offset: try table.integer(at: start + 32, bytes: 8),
                decryptLength: min(size, try table.integer(at: start + 48, bytes: 8)), cipher: .aes(key: key, iv: iv)))
        }
        return try make(snapshot, format: .ofpMediaTek, entries: entries, metadata: Data(), name: "", dataEnd: tableOffset)
    }

    private static func readQC(_ snapshot: FileSnapshot, input: FileHandle, control: WorkControl) throws -> FirmwarePackage {
        var pageSize: UInt64 = 0
        for page: UInt64 in [512, 4096] where snapshot.size >= page {
            let magic = try input.readExactly(offset: snapshot.size - page + 16, count: 4, fileSize: snapshot.size)
            if try magic.integer(at: 0, bytes: 4) == 0x7cef { pageSize = page; break }
        }
        guard pageSize > 0 else { throw InputError.invalid("无法识别高通 OFP 页大小或格式。") }
        let footer = snapshot.size - pageSize
        let header = try input.readExactly(offset: footer + 20, count: 8, fileSize: snapshot.size)
        let offset = try checkedMultiply(header.integer(at: 0, bytes: 4), pageSize)
        var length = try header.integer(at: 4, bytes: 4)
        if length < 200 {
            guard offset <= footer, footer - offset > 0x57 else { throw InputError.invalid("高通 OFP XML 偏移无效。") }
            length = footer - offset - 0x57
        }
        guard length > 0, length <= 32 * 1024 * 1024, offset <= footer, length <= footer - offset else { throw InputError.invalid("高通 OFP XML 超出范围或过大。") }
        let encoded = try input.readExactly(offset: offset, count: Int(length), fileSize: snapshot.size)
        for table in OFPKeys.qualcomm {
            try control.check()
            let (key, iv) = try derive(table)
            let decoded = try FirmwareDecryptor.decrypt(encoded, cipher: .aes(key: key, iv: iv))
            guard let start = decoded.range(of: Data("<?xml".utf8))?.lowerBound, let end = decoded.lastIndex(of: 62), end >= start,
                  let text = String(data: decoded.subdata(in: start..<(end + 1)), encoding: .utf8), let root = try? FirmwareXML.parse(text) else { continue }
            var entries: [FirmwareEntry] = []
            for node in root.descendants {
                guard let path = node.attribute("Path") ?? node.attribute("filename"), !path.isEmpty,
                      let sectorOffset = node.number("FileOffsetInSrc") ?? node.number("SizeInSectorInSrc") else { continue }
                let rawSize = node.number("SizeInByteInSrc") ?? 0, sectors = node.number("SizeInSectorInSrc") ?? 0
                let category = node.parent?.name.lowercased() ?? ""
                let exactBytes = ["config", "provision", "chainedtableofdigests", "digeststosign", "firmware"].contains(category)
                let copyRaw = ["digeststosign", "chainedtableofdigests", "firmware"].contains(category)
                let readSize = exactBytes && rawSize > 0 ? rawSize : (sectors > 0 ? try checkedMultiply(sectors, pageSize) : rawSize)
                guard readSize > 0 else { continue }
                let decryptSize = copyRaw ? 0 : min(readSize, category == "sahara" ? rawSize : min(0x40000, rawSize))
                entries.append(FirmwareEntry(path: path, size: readSize, offset: try checkedMultiply(sectorOffset, pageSize),
                    decryptLength: decryptSize, cipher: .aes(key: key, iv: iv)))
            }
            return try make(snapshot, format: .ofpQualcomm, entries: entries, metadata: Data(text.utf8), name: "ProFile.xml", dataEnd: footer)
        }
        throw InputError.invalid("未找到匹配的高通 OFP 密钥，可能是尚未支持的新格式。")
    }

    private static func make(_ snapshot: FileSnapshot, format: Format, entries: [FirmwareEntry], metadata: Data, name: String, dataEnd: UInt64) throws -> FirmwarePackage {
        var seen: [String: FirmwareEntry] = [:], result: [FirmwareEntry] = []
        for entry in entries {
            let path = try ArchivePaths.normalize(entry.path)
            if !name.isEmpty, path.lowercased() == name.lowercased() { continue }
            guard entry.offset <= dataEnd, entry.size <= dataEnd - entry.offset else { throw InputError.invalid("固件文件表越界：\(path)") }
            let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
            if let previous = seen[normalized] {
                guard previous.path == path, previous.offset == entry.offset, previous.size == entry.size,
                      previous.decryptLength == entry.decryptLength else { throw InputError.invalid("固件包含冲突的重复路径：\(path)") }
                continue
            }
            let copy = FirmwareEntry(path: path, size: entry.size, offset: entry.offset, decryptLength: entry.decryptLength, cipher: entry.cipher)
            seen[normalized] = copy; result.append(copy)
        }
        guard !result.isEmpty, result.count <= 100_000 else { throw InputError.invalid("固件中没有可提取文件，或文件数量过大。") }
        let allNames = Set(result.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() } + (name.isEmpty ? [] : [name.lowercased()]))
        for path in allNames {
            var components = path.components(separatedBy: "/")
            while components.count > 1 {
                components.removeLast()
                guard !allNames.contains(components.joined(separator: "/")) else { throw InputError.invalid("固件同时将同一路径用作文件和文件夹。") }
            }
        }
        try snapshot.validate()
        return FirmwarePackage(sourceURL: snapshot.url, format: format, entries: result, snapshot: snapshot, metadata: metadata, metadataName: name)
    }

    static func derive(_ table: [String]) throws -> (Data, Data) {
        if table.count == 2 { return (Data(table[0].utf8), Data(table[1].utf8)) }
        guard table.count == 3 else { throw InputError.invalid("OFP 密钥表无效。") }
        func unhex(_ text: String) throws -> [UInt8] {
            let chars = Array(text)
            guard chars.count % 2 == 0 else { throw InputError.invalid("OFP 密钥无效。") }
            return try stride(from: 0, to: chars.count, by: 2).map { index in
                guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { throw InputError.invalid("OFP 密钥无效。") }; return byte
            }
        }
        let mask = try unhex(table[0])
        guard !mask.isEmpty else { throw InputError.invalid("OFP 掩码为空。") }
        let values = try table.dropFirst().map { text -> Data in
            let bytes = try unhex(text).enumerated().map { index, byte -> UInt8 in let mixed = byte ^ mask[index % mask.count]; return (mixed << 4) | (mixed >> 4) }
            let hex = Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            return Data(hex.prefix(16).utf8)
        }
        return (values[0], values[1])
    }

    private static func shuffle(_ data: Data) -> Data {
        let key = Array("geyixue".utf8)
        return Data(data.enumerated().map { index, value in key[index % key.count] ^ ((value << 4) | (value >> 4)) })
    }

    public func extract(names: Set<String>, to directory: URL, control: WorkControl = WorkControl(),
                        progress: @escaping @Sendable (WorkProgress) -> Void = { _ in }) throws -> [URL] {
        try control.check(); try snapshot.validate()
        let selected = entries.filter { names.contains($0.path) }
        guard !selected.isEmpty, selected.count == names.count else { throw InputError.invalid("请选择有效的固件文件。") }
        let outputNames = selected.map(\.path) + (metadataName.isEmpty ? [] : [metadataName])
        for name in outputNames {
            let target = try ArchivePaths.destination(root: directory, name: name, createParents: false)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw InputError.invalid("目标已存在，未覆盖：\(name)") }
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let total = try selected.reduce(UInt64(0)) { try checkedAdd($0, $1.size) }
        var done: UInt64 = 0, files: [URL] = []
        if !metadataName.isEmpty {
            let target = try AtomicOutput(ArchivePaths.destination(root: directory, name: metadataName, createParents: true))
            try target.handle.write(contentsOf: metadata); files.append(try target.commit())
        }
        for entry in selected {
            try control.check()
            let target = try AtomicOutput(ArchivePaths.destination(root: directory, name: entry.path, createParents: true))
            let decryptor = try FirmwareDecryptor(entry.cipher, length: entry.decryptLength)
            var position: UInt64 = 0, written: UInt64 = 0
            while position < entry.size {
                try control.check()
                let decrypting = position < entry.decryptLength
                let end = decrypting ? entry.decryptLength : entry.size
                let count = Int(min(1024 * 1024, end - position))
                let data = try input.readExactly(offset: checkedAdd(entry.offset, position), count: count, fileSize: snapshot.size)
                let decoded = decrypting ? try decryptor.update(data) : data
                try target.handle.write(contentsOf: decoded); written += UInt64(decoded.count); position += UInt64(count)
                if decrypting, position == entry.decryptLength {
                    let tail = try decryptor.finish(); try target.handle.write(contentsOf: tail); written += UInt64(tail.count)
                }
                progress(WorkProgress("解包 \(entry.path)", done: done + position, total: total))
            }
            guard written == entry.size else { throw InputError.invalid("文件解密输出长度不一致：\(entry.path)") }
            try control.check(); try snapshot.validate()
            files.append(try target.commit()); done += entry.size
        }
        return files
    }
}
