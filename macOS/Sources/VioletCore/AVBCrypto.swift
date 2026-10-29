import Foundation
import CryptoKit
import Security

enum AVBDER {
    static func wrap(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = Data()
        if bytes.count < 128 { length.append(UInt8(bytes.count)) }
        else {
            var n = bytes.count, encoded = Data()
            while n > 0 { encoded.insert(UInt8(n & 255), at: 0); n >>= 8 }
            length.append(0x80 | UInt8(encoded.count)); length += encoded
        }
        return Data([tag]) + length + bytes
    }
    static func integer(_ bytes: Data) -> Data {
        var canonical = Data(bytes.drop(while: { $0 == 0 }))
        if canonical.isEmpty { canonical = Data([0]) }
        if canonical[0] & 128 != 0 { canonical.insert(0, at: 0) }
        return wrap(2, canonical)
    }
    struct Reader {
        let bytes: Data
        var offset = 0
        mutating func read(_ tag: UInt8) throws -> Data {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw InputError.invalid("RSA DER 标签无效。") }
            offset += 1
            let first = Int(bytes[offset]); offset += 1
            var length = first
            if first >= 128 {
                let count = first & 127
                guard count > 0, count <= 4, offset + count <= bytes.count, bytes[offset] != 0 else { throw InputError.invalid("RSA DER 长度无效。") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
                guard length >= 128 else { throw InputError.invalid("RSA DER 长度编码不规范。") }
            }
            guard length <= bytes.count - offset else { throw InputError.invalid("RSA DER 数据已截断。") }
            let result = bytes.subdata(in: offset..<offset + length); offset += length
            return result
        }
        func finish() throws { guard offset == bytes.count else { throw InputError.invalid("RSA DER 包含多余数据。") } }
    }
    static func contents(_ data: Data) throws -> Reader {
        var reader = Reader(bytes: data)
        let sequence = try reader.read(0x30); try reader.finish()
        return Reader(bytes: sequence)
    }
}

struct AVBRSA {
    let key: SecKey
    let bits: Int
    let publicBlob: Data
    init(privatePEM url: URL) throws {
        let snapshot = try FileSnapshot(url)
        guard snapshot.size <= 65536 else { throw InputError.invalid("RSA PEM 文件过大。") }
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pkcs8 = text.hasPrefix("-----BEGIN PRIVATE KEY-----")
        let label = pkcs8 ? "PRIVATE KEY" : "RSA PRIVATE KEY"
        let begin = "-----BEGIN \(label)-----", end = "-----END \(label)-----"
        guard text.hasPrefix(begin), text.hasSuffix(end) else { throw InputError.invalid("请选择未加密的 RSA PKCS#1 / PKCS#8 PEM 私钥。") }
        let body = text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard var der = Data(base64Encoded: String(body)) else { throw InputError.invalid("RSA PEM Base64 无效。") }
        if pkcs8 {
            var sequence = try AVBDER.contents(der)
            guard try sequence.read(2) == Data([0]) else { throw InputError.invalid("不支持此 PKCS#8 版本。") }
            var algorithm = try AVBDER.contents(AVBDER.wrap(0x30, sequence.read(0x30)))
            guard try algorithm.read(6) == Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1]), try algorithm.read(5).isEmpty else { throw InputError.invalid("PKCS#8 必须是 RSA 密钥。") }
            try algorithm.finish(); der = try sequence.read(4); try sequence.finish()
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(key), let representation = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw InputError.invalid("无法导入 RSA 私钥。") }
        var sequence = try AVBDER.contents(representation)
        let modulus = Data(try sequence.read(2).drop(while: { $0 == 0 }))
        guard try sequence.read(2) == Data([1,0,1]) else { throw InputError.invalid("AVB RSA 公钥指数必须为 65537。") }
        try sequence.finish()
        bits = modulus.count * 8
        guard [2048,4096,8192].contains(bits), modulus.first! & 128 != 0, modulus.last! & 1 == 1 else { throw InputError.invalid("RSA 密钥需为 2048 / 4096 / 8192 位。") }
        self.key = key
        publicBlob = try Self.blob(modulus: modulus)
        try snapshot.validate()
    }
    static func blob(modulus: Data) throws -> Data {
        let bits = modulus.count * 8, count = modulus.count / 4
        guard [2048,4096,8192].contains(bits) else { throw InputError.invalid("AVB RSA 位数不支持。") }
        var n = [UInt32](repeating: 0, count: count)
        for i in 0..<count { n[i] = UInt32(try modulus.integer(at: modulus.count - 4 - i * 4, bytes: 4, bigEndian: true)) }
        guard n[0] & 1 == 1, n[count - 1] & 0x80000000 != 0 else { throw InputError.invalid("AVB RSA 模数无效。") }
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }
        var rr = [UInt32](repeating: 0, count: count); rr[0] = 1
        for _ in 0..<(2 * bits) {
            var carry: UInt32 = 0
            for i in 0..<count { let next = rr[i] >> 31; rr[i] = rr[i] << 1 | carry; carry = next }
            var greater = carry != 0
            if !greater {
                greater = true
                for i in (0..<count).reversed() where rr[i] != n[i] { greater = rr[i] > n[i]; break }
            }
            if greater {
                var borrow: UInt64 = 0
                for i in 0..<count { let value = UInt64(n[i]) + borrow; let old = UInt64(rr[i]); rr[i] = UInt32(truncatingIfNeeded: old &- value); borrow = old < value ? 1 : 0 }
            }
        }
        var blob = Data(); blob.appendBE(UInt64(bits), bytes: 4); blob.appendBE(UInt64(0 &- inverse), bytes: 4); blob += modulus
        for word in rr.reversed() { blob.appendBE(UInt64(word), bytes: 4) }
        return blob
    }
    static func publicKey(_ blob: Data) throws -> SecKey {
        let bits = try blob.integer(at: 0, bytes: 4, bigEndian: true)
        guard [2048,4096,8192].contains(bits), blob.count == 8 + Int(bits / 8) * 2 else { throw InputError.invalid("AVB RSA 公钥长度无效。") }
        let modulus = blob.subdata(in: 8..<8 + Int(bits / 8))
        guard try Self.blob(modulus: modulus) == blob else { throw InputError.invalid("AVB RSA Montgomery 参数无效。") }
        let der = AVBDER.wrap(0x30, AVBDER.integer(modulus) + AVBDER.integer(Data([1,0,1])))
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error) else { throw InputError.invalid("AVB RSA 公钥无效。") }
        return key
    }
}

extension Data {
    mutating func appendBE(_ value: UInt64, bytes: Int) { for i in (0..<bytes).reversed() { append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
    mutating func putBE(_ value: UInt64, at offset: Int, bytes: Int) { var encoded = Data(); encoded.appendBE(value, bytes: bytes); replaceSubrange(offset..<offset + bytes, with: encoded) }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
