import Foundation
import Darwin
import VioletNative

struct FileSnapshot: Sendable {
    let url: URL
    let size: UInt64
    private let modified: Date?
    private let inode: UInt64?
    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw InputError.invalid("请选择普通文件。") }
        self.url = url
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
    func validate() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == size,
              attributes[.modificationDate] as? Date == modified,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode else {
            throw InputError.invalid("源文件已变化，请重新分析：\(url.lastPathComponent)")
        }
    }
}

final class AtomicOutput {
    let destination: URL
    let temporary: URL
    let handle: FileHandle
    private var committed = false
    init(_ destination: URL) throws {
        self.destination = destination
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw InputError.invalid("目标已存在，未覆盖：\(destination.lastPathComponent)") }
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".violet-" + UUID().uuidString + ".partial")
        let fd = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InputError.invalid("无法创建输出文件，请检查目录和磁盘空间。") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func commit() throws -> URL {
        try handle.synchronize(); try handle.close()
        // An exclusive rename also protects against an existing file appearing
        // between the initial existence check and completion.
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw InputError.invalid("无法保存输出，目标可能已存在：\(destination.lastPathComponent)")
        }
        committed = true
        return destination
    }
    deinit { try? handle.close(); if !committed { try? FileManager.default.removeItem(at: temporary) } }
}

/// Lets a trusted CLI write a uniquely named staging file without exposing or
/// replacing the final path. Replacing the staging inode is rejected as well.
public final class ExternalToolOutput {
    private let output: AtomicOutput
    public var url: URL { output.temporary }
    public init(_ destination: URL) throws { output = try AtomicOutput(destination) }
    public func commit(expectedSize: UInt64) throws {
        var descriptor = stat(), path = stat()
        guard expectedSize > 0, fstat(output.handle.fileDescriptor, &descriptor) == 0,
              lstat(output.temporary.path, &path) == 0, descriptor.st_ino == path.st_ino, descriptor.st_dev == path.st_dev,
              path.st_mode & S_IFMT == S_IFREG, descriptor.st_size >= 0, UInt64(descriptor.st_size) == expectedSize else {
            throw InputError.invalid("外部工具输出长度不符或临时文件被替换。")
        }
        _ = try output.commit()
    }
}

enum ArchivePaths {
    static func normalize(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.components(separatedBy: "/").filter { $0 != "." }
        guard !normalized.isEmpty, normalized.utf8.count <= 4096,
              !normalized.contains(":"), !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." }) else {
            throw InputError.invalid("固件包含不安全的文件路径：\(value.prefix(160))")
        }
        return parts.joined(separator: "/")
    }
    static func destination(root: URL, name: String, createParents: Bool) throws -> URL {
        let normalized = try normalize(name)
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var current = base
        for (index, component) in normalized.components(separatedBy: "/").enumerated() {
            current.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw InputError.invalid("输出路径包含符号链接。") }
                if index != normalized.components(separatedBy: "/").count - 1,
                   attributes[.type] as? FileAttributeType != .typeDirectory { throw InputError.invalid("输出父路径不是文件夹。") }
            } else if createParents, index != normalized.components(separatedBy: "/").count - 1 {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        return current
    }
}

enum FirmwareCipher: Sendable {
    case none
    case aes(key: Data, iv: Data)
    case ops(version: Int)
}

final class FirmwareDecryptor {
    private let cipher: FirmwareCipher
    private var context: UnsafeMutableRawPointer?
    private var remaining: UInt64
    init(_ cipher: FirmwareCipher, length: UInt64) throws {
        self.cipher = cipher; remaining = length
        switch cipher {
        case .none: break
        case let .aes(key, iv):
            guard key.count == 16, iv.count == 16 else { throw InputError.invalid("OFP AES 参数长度无效。") }
            context = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                violet_cfb_create(key.bindMemory(to: UInt8.self).baseAddress, iv.bindMemory(to: UInt8.self).baseAddress)
            } }
        case let .ops(version): context = violet_ops_create(Int32(version), length)
        }
        if case .none = cipher { return }
        guard context != nil else { throw InputError.invalid("无法初始化固件解密器。") }
    }
    func update(_ input: Data) throws -> Data {
        guard UInt64(input.count) <= remaining else { throw InputError.invalid("解密输入长度超出声明范围。") }
        remaining -= UInt64(input.count)
        if case .none = cipher { return input }
        var output = Data(count: input.count + 32), written = 0
        let result = output.withUnsafeMutableBytes { target in input.withUnsafeBytes { source in
            if case .ops = cipher {
                written = input.count
                return violet_ops_update(context, source.bindMemory(to: UInt8.self).baseAddress, target.bindMemory(to: UInt8.self).baseAddress, input.count)
            }
            return violet_cfb_update(context, source.bindMemory(to: UInt8.self).baseAddress, input.count,
                                     target.bindMemory(to: UInt8.self).baseAddress, input.count + 32, &written)
        } }
        guard result == 0 else { throw InputError.invalid("固件数据解密失败（\(result)）。") }
        output.count = written
        return output
    }
    func finish() throws -> Data {
        guard remaining == 0 else { throw InputError.invalid("固件加密数据不完整。") }
        guard case .aes = cipher else { return Data() }
        var output = Data(count: 32), written = 0
        let result = output.withUnsafeMutableBytes { target in violet_cfb_finish(context, target.bindMemory(to: UInt8.self).baseAddress, 32, &written) }
        guard result == 0 else { throw InputError.invalid("固件解密尾部不完整。") }
        output.count = written; return output
    }
    static func decrypt(_ input: Data, cipher: FirmwareCipher) throws -> Data {
        let worker = try FirmwareDecryptor(cipher, length: UInt64(input.count))
        return try worker.update(input) + worker.finish()
    }
    deinit {
        if case .ops = cipher { violet_ops_free(context) }
        else if case .aes = cipher { violet_cfb_free(context) }
    }
}

final class FirmwareXMLNode {
    let name: String
    let attributes: [String: String]
    weak var parent: FirmwareXMLNode?
    var children: [FirmwareXMLNode] = []
    init(name: String, attributes: [String: String]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
    func attribute(_ key: String) -> String? { attributes[key.lowercased()] }
    func number(_ key: String) -> UInt64? { attribute(key).flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    var descendants: [FirmwareXMLNode] { children.flatMap { [$0] + $0.descendants } }
}

private final class FirmwareXMLParser: NSObject, XMLParserDelegate {
    var root: FirmwareXMLNode?
    var stack: [FirmwareXMLNode] = []
    var count = 0
    var rejected = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 64, count <= 100_000, attributes.count <= 1024 else { rejected = true; parser.abortParsing(); return }
        let node = FirmwareXMLNode(name: elementName, attributes: attributes)
        node.parent = stack.last
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejected = true; parser.abortParsing() }
}

enum FirmwareXML {
    static func parse(_ value: String) throws -> FirmwareXMLNode {
        guard value.utf8.count <= 32 * 1024 * 1024, !value.uppercased().contains("<!DOCTYPE"), !value.uppercased().contains("<!ENTITY") else {
            throw InputError.invalid("固件 XML 过大或包含不支持的 DTD / 实体声明。")
        }
        let parser = XMLParser(data: Data(value.utf8)), delegate = FirmwareXMLParser()
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.rejected, let root = delegate.root else { throw InputError.invalid("固件 XML 无效或超出解析限制。") }
        return root
    }
}
