import Foundation
import CryptoKit
import Security

public struct AVBHashDescriptor: Sendable, Identifiable {
    public let partition: String
    public let imageSize: UInt64
    public let algorithm: String
    public let salt: Data
    public let digest: Data
    public var id: String { partition }
}

public struct AVBVerification: Sendable {
    public let signature: String
    public let partitions: [String]
    public var description: String { ([signature] + partitions).joined(separator: "\n") }
}

public struct AVBImage: Sendable {
    public let sourceURL: URL
    public let algorithm: UInt64
    public let rollbackIndex: UInt64
    public let flags: UInt64
    public let originalSize: UInt64?
    public let hashes: [AVBHashDescriptor]
    public let descriptorTags: [UInt64]
    public let publicKeySHA256: String
    public let partitionSize: UInt64
    private let header: Data
    private let auth: Data
    private let auxiliary: Data
    private let key: Data
    private let snapshot: FileSnapshot

    public static func open(_ url: URL) throws -> AVBImage {
        let snapshot = try FileSnapshot(url), file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var offset: UInt64 = 0, size = snapshot.size, original: UInt64?
        let magic = try file.readExactly(offset: 0, count: 4, fileSize: snapshot.size)
        if magic != Data("AVB0".utf8) {
            guard size >= 64 else { throw InputError.invalid("镜像没有 AVB header / footer。") }
            let footer = try file.readExactly(offset: size - 64, count: 64, fileSize: size)
            guard footer.prefix(4) == Data("AVBf".utf8), try footer.integer(at: 4, bytes: 4, bigEndian: true) == 1 else { throw InputError.invalid("镜像没有受支持的 AVB footer。") }
            original = try footer.integer(at: 12, bytes: 8, bigEndian: true)
            offset = try footer.integer(at: 20, bytes: 8, bigEndian: true)
            size = try footer.integer(at: 28, bytes: 8, bigEndian: true)
            guard original! <= offset, size >= 256, try checkedAdd(offset, size) <= snapshot.size - 64 else { throw InputError.invalid("AVB footer 范围无效。") }
        }
        let header = try file.readExactly(offset: offset, count: 256, fileSize: snapshot.size)
        guard header.prefix(4) == Data("AVB0".utf8), try header.integer(at: 4, bytes: 4, bigEndian: true) == 1,
              try header.integer(at: 8, bytes: 4, bigEndian: true) <= 3 else { throw InputError.invalid("AVB header 版本不支持。") }
        func u(_ p: Int) throws -> UInt64 { try header.integer(at: p, bytes: 8, bigEndian: true) }
        let authSize = try u(12), auxSize = try u(20)
        let total = try checkedAdd(256, checkedAdd(authSize, auxSize))
        guard authSize % 64 == 0, auxSize % 64 == 0, total <= size, total <= 8 * 1024 * 1024 else { throw InputError.invalid("AVB 元数据大小、对齐或范围无效。") }
        let auth = try file.readExactly(offset: offset + 256, count: Int(authSize), fileSize: snapshot.size)
        let aux = try file.readExactly(offset: offset + 256 + authSize, count: Int(auxSize), fileSize: snapshot.size)
        func region(_ data: Data, _ position: UInt64, _ length: UInt64) throws -> Data {
            guard position <= data.count, length <= UInt64(data.count) - position else { throw InputError.invalid("AVB 区块越界。") }
            return data.subdata(in: Int(position)..<Int(position + length))
        }
        _ = try region(auth, u(32), u(40)); _ = try region(auth, u(48), u(56))
        let key = try region(aux, u(64), u(72))
        _ = try region(aux, u(80), u(88))
        let descriptors = try region(aux, u(96), u(104))
        var position = 0, hashes: [AVBHashDescriptor] = [], tags: [UInt64] = []
        while position < descriptors.count {
            guard tags.count < 4096 else { throw InputError.invalid("AVB 描述符过多。") }
            let tag = try descriptors.integer(at: position, bytes: 8, bigEndian: true)
            let length = try descriptors.integer(at: position + 8, bytes: 8, bigEndian: true)
            guard length % 8 == 0, descriptors.count - position >= 16, length <= UInt64(descriptors.count - position - 16) else { throw InputError.invalid("AVB 描述符长度无效。") }
            let descriptor = descriptors.subdata(in: position..<position + 16 + Int(length))
            tags.append(tag)
            if tag == 2 {
                guard descriptor.count >= 132 else { throw InputError.invalid("AVB hash 描述符不完整。") }
                let nameLength = try descriptor.integer(at: 56, bytes: 4, bigEndian: true)
                let saltLength = try descriptor.integer(at: 60, bytes: 4, bigEndian: true)
                let digestLength = try descriptor.integer(at: 64, bytes: 4, bigEndian: true)
                let dataLength = try checkedAdd(nameLength, checkedAdd(saltLength, digestLength))
                guard dataLength <= UInt64(descriptor.count - 132), nameLength <= 128, saltLength <= 4096 else { throw InputError.invalid("AVB hash 描述符字段越界。") }
                let name = String(decoding: descriptor[132..<132 + Int(nameLength)], as: UTF8.self)
                guard name.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil, !hashes.contains(where: { $0.partition == name }) else { throw InputError.invalid("AVB 分区名无效或重复。") }
                let algorithm = String(decoding: descriptor[24..<56].prefix(while: { $0 != 0 }), as: UTF8.self)
                let saltStart = 132 + Int(nameLength), digestStart = saltStart + Int(saltLength)
                hashes.append(AVBHashDescriptor(partition: name, imageSize: try descriptor.integer(at: 16, bytes: 8, bigEndian: true), algorithm: algorithm,
                    salt: descriptor.subdata(in: saltStart..<digestStart), digest: descriptor.subdata(in: digestStart..<digestStart + Int(digestLength))))
            }
            position += 16 + Int(length)
        }
        try snapshot.validate()
        return AVBImage(sourceURL: url, algorithm: try header.integer(at: 28, bytes: 4, bigEndian: true), rollbackIndex: try u(112),
                        flags: try header.integer(at: 120, bytes: 4, bigEndian: true), originalSize: original, hashes: hashes,
                        descriptorTags: tags, publicKeySHA256: key.isEmpty ? "无公钥" : Data(SHA256.hash(data: key)).hexString,
                        partitionSize: snapshot.size, header: header, auth: auth, auxiliary: aux, key: key, snapshot: snapshot)
    }

    public func verify(images: [String: URL] = [:], control: WorkControl = WorkControl(), progress: @Sendable (WorkProgress) -> Void = { _ in }) throws -> AVBVerification {
        try control.check(); try snapshot.validate()
        let signatureStatus: String
        if algorithm == 0 { signatureStatus = "签名：未签名（algorithm NONE）" }
        else {
            guard (1...6).contains(algorithm) else { throw InputError.invalid("AVB 签名算法不支持：\(algorithm)") }
            let use512 = algorithm >= 4, bits = [2048,4096,8192][Int((algorithm - 1) % 3)]
            guard try key.integer(at: 0, bytes: 4, bigEndian: true) == UInt64(bits) else { throw InputError.invalid("AVB 算法与公钥位数不匹配。") }
            let message = header + auxiliary
            let digest = use512 ? Data(SHA512.hash(data: message)) : Data(SHA256.hash(data: message))
            let hashOffset = Int(try header.integer(at: 32, bytes: 8, bigEndian: true)), hashSize = Int(try header.integer(at: 40, bytes: 8, bigEndian: true))
            let sigOffset = Int(try header.integer(at: 48, bytes: 8, bigEndian: true)), sigSize = Int(try header.integer(at: 56, bytes: 8, bigEndian: true))
            guard hashSize == digest.count, sigSize == bits / 8, auth.subdata(in: hashOffset..<hashOffset + hashSize) == digest else { throw InputError.invalid("AVB 认证摘要不匹配。") }
            let pub = try AVBRSA.publicKey(key)
            var error: Unmanaged<CFError>?
            guard SecKeyVerifySignature(pub, use512 ? .rsaSignatureDigestPKCS1v15SHA512 : .rsaSignatureDigestPKCS1v15SHA256,
                                        digest as CFData, auth.subdata(in: sigOffset..<sigOffset + sigSize) as CFData, &error) else { throw InputError.invalid("AVB RSA 签名校验失败。") }
            signatureStatus = "签名：通过（使用镜像内嵌公钥；未验证厂商信任链）"
        }
        var results: [String] = []
        for descriptor in hashes {
            let selfImage = originalSize != nil && hashes.count == 1 ? sourceURL : nil
            guard let url = images[descriptor.partition] ?? selfImage else { results.append("\(descriptor.partition)：未校验，缺少分区镜像"); continue }
            if url == sourceURL, let originalSize, descriptor.imageSize > originalSize { throw InputError.invalid("AVB hash 范围超出原始镜像。") }
            let digest = try Self.hashFile(url, size: descriptor.imageSize, salt: descriptor.salt, algorithm: descriptor.algorithm, control: control, progress: progress)
            guard digest == descriptor.digest else { throw InputError.invalid("\(descriptor.partition) 镜像数据摘要不匹配。") }
            results.append("\(descriptor.partition)：\(descriptor.algorithm) 数据摘要通过（\(descriptor.imageSize) bytes）")
        }
        if descriptorTags.contains(1) { results.append("Hashtree：尚未校验树及对应分区") }
        if descriptorTags.contains(4) { results.append("Chain partition：尚未校验下级 vbmeta 与信任链") }
        if descriptorTags.contains(where: { ![0,1,2,3,4].contains($0) }) { results.append("包含尚未校验的扩展描述符") }
        if flags != 0 { results.append("AVB flags = \(flags)，请核对启动验证策略") }
        try snapshot.validate(); try control.check()
        return AVBVerification(signature: signatureStatus, partitions: results)
    }

    static func hashFile(_ url: URL, size: UInt64, salt: Data, algorithm: String, control: WorkControl, progress: @Sendable (WorkProgress) -> Void) throws -> Data {
        guard ["sha256", "sha512"].contains(algorithm) else { throw InputError.invalid("不支持分区 hash：\(algorithm)") }
        let snapshot = try FileSnapshot(url)
        guard size <= snapshot.size else { throw InputError.invalid("分区镜像大小不足。") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var sha256 = SHA256(), sha512 = SHA512(), done: UInt64 = 0
        sha256.update(data: salt); sha512.update(data: salt)
        while done < size {
            try control.check()
            let bytes = try file.readExactly(offset: done, count: Int(min(1024 * 1024, size - done)), fileSize: snapshot.size)
            if algorithm == "sha256" { sha256.update(data: bytes) } else { sha512.update(data: bytes) }
            done += UInt64(bytes.count); progress(WorkProgress(url.lastPathComponent, done: done, total: size))
        }
        try snapshot.validate(); try control.check()
        return algorithm == "sha256" ? Data(sha256.finalize()) : Data(sha512.finalize())
    }

    public static func signCopy(source: URL, destination: URL, privateKey: URL, partition: String, partitionSize: UInt64, rollback: UInt64 = 0,
                                salt: Data? = nil, control: WorkControl = WorkControl(), progress: @Sendable (WorkProgress) -> Void = { _ in }) throws -> URL {
        try control.check()
        guard partition.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else { throw InputError.invalid("分区名无效。") }
        let snapshot = try FileSnapshot(source), file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var originalSize = snapshot.size
        if try file.readExactly(offset: 0, count: 4, fileSize: snapshot.size) == Data("AVB0".utf8) { throw InputError.invalid("此工具签名分区 hash footer；独立 vbmeta 的信任链重建尚不支持。") }
        if snapshot.size >= 64, try file.readExactly(offset: snapshot.size - 64, count: 4, fileSize: snapshot.size) == Data("AVBf".utf8) {
            let existing = try open(source)
            guard let size = existing.originalSize, !existing.descriptorTags.contains(1) else { throw InputError.invalid("Hashtree 镜像不能转换为 hash footer。") }
            originalSize = size
        }
        guard originalSize > 0, partitionSize % 4096 == 0, partitionSize <= 1 << 40,
              partitionSize >= 69632, originalSize <= partitionSize - 69632 else { throw InputError.invalid("分区大小需按 4096 对齐，并比原始镜像至少多 68 KiB；请填写真实分区容量（bytes）。") }
        let rsa = try AVBRSA(privatePEM: privateKey)
        let generateSalt = salt == nil
        var salt = salt ?? Data(count: 32)
        if generateSalt {
            let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard result == errSecSuccess else { throw InputError.invalid("无法生成随机 salt。") }
        }
        guard salt.count <= 4096 else { throw InputError.invalid("AVB salt 过长。") }
        let digest = try hashFile(source, size: originalSize, salt: salt, algorithm: "sha256", control: control, progress: progress)
        var descriptor = Data(count: 132)
        descriptor.putBE(2, at: 0, bytes: 8); descriptor.putBE(originalSize, at: 16, bytes: 8)
        descriptor.replaceSubrange(24..<30, with: Data("sha256".utf8))
        descriptor.putBE(UInt64(partition.utf8.count), at: 56, bytes: 4); descriptor.putBE(UInt64(salt.count), at: 60, bytes: 4); descriptor.putBE(32, at: 64, bytes: 4)
        descriptor += Data(partition.utf8) + salt + digest
        descriptor += Data(count: (8 - descriptor.count % 8) % 8)
        descriptor.putBE(UInt64(descriptor.count - 16), at: 8, bytes: 8)
        var auxiliary = descriptor + rsa.publicBlob
        auxiliary += Data(count: (64 - auxiliary.count % 64) % 64)
        let authSize = (32 + rsa.bits / 8 + 63) / 64 * 64
        var header = Data(count: 256)
        header.replaceSubrange(0..<4, with: Data("AVB0".utf8)); header.putBE(1, at: 4, bytes: 4)
        header.putBE(UInt64(authSize), at: 12, bytes: 8); header.putBE(UInt64(auxiliary.count), at: 20, bytes: 8)
        header.putBE(UInt64([2048: 1,4096: 2,8192: 3][rsa.bits]!), at: 28, bytes: 4)
        header.putBE(32, at: 40, bytes: 8); header.putBE(32, at: 48, bytes: 8); header.putBE(UInt64(rsa.bits / 8), at: 56, bytes: 8)
        header.putBE(UInt64(descriptor.count), at: 64, bytes: 8); header.putBE(UInt64(rsa.publicBlob.count), at: 72, bytes: 8)
        header.putBE(UInt64(descriptor.count), at: 104, bytes: 8); header.putBE(rollback, at: 112, bytes: 8)
        let release = Data("VioletToolBox macOS".utf8); header.replaceSubrange(128..<128 + release.count, with: release)
        let authenticationHash = Data(SHA256.hash(data: header + auxiliary))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(rsa.key, .rsaSignatureDigestPKCS1v15SHA256, authenticationHash as CFData, &error) as Data? else { throw InputError.invalid("RSA 签名失败。") }
        var auth = authenticationHash + signature; auth += Data(count: authSize - auth.count)
        let vbmeta = header + auth + auxiliary, metaOffset = (originalSize + 4095) / 4096 * 4096
        guard metaOffset + UInt64(vbmeta.count) <= partitionSize - 4096 else { throw InputError.invalid("AVB 元数据超出分区容量。") }
        var footer = Data(count: 64)
        footer.replaceSubrange(0..<4, with: Data("AVBf".utf8)); footer.putBE(1, at: 4, bytes: 4)
        footer.putBE(originalSize, at: 12, bytes: 8); footer.putBE(metaOffset, at: 20, bytes: 8); footer.putBE(UInt64(vbmeta.count), at: 28, bytes: 8)
        let output = try AtomicOutput(destination)
        var done: UInt64 = 0
        while done < originalSize {
            try control.check()
            let bytes = try file.readExactly(offset: done, count: Int(min(1024 * 1024, originalSize - done)), fileSize: snapshot.size)
            try output.handle.write(contentsOf: bytes); done += UInt64(bytes.count)
        }
        try output.handle.truncate(atOffset: partitionSize)
        try output.handle.seek(toOffset: metaOffset); try output.handle.write(contentsOf: vbmeta)
        try output.handle.seek(toOffset: partitionSize - 64); try output.handle.write(contentsOf: footer)
        try output.handle.synchronize(); try snapshot.validate(); try control.check()
        _ = try open(output.temporary).verify(control: control, progress: progress)
        try control.check(); return try output.commit()
    }
}
