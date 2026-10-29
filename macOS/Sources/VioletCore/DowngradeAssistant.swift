import Foundation
import CryptoKit
import Security
import Darwin
import VioletNative

// Wire format and key derivation mirror VioletToolBox/DowngradeTool.cs.
// Neither this socket nor the remote query installs a firmware by itself.
public struct DowngradeDeviceInfo: Sendable, Equatable {
    public let serial: String
    public let model: String
    public let otaVersion: String
    public let project: String
    public let carrier: String
    public let androidVersion: String
    public let colorOSVersion: String
    fileprivate let duid: String

    fileprivate init(_ info: [String: Any], serial: String) throws {
        let outer = try DowngradeJSON.object(info["downgradeRequestBody"])
        let body = outer["params"] == nil ? outer : try DowngradeJSON.object(outer["params"])
        let id = DowngradeJSON.string(body,"deviceId")
        guard !id.isEmpty, id.utf8.count <= 4096, !id.allSatisfy({ $0 == "0" }) else { throw InputError.invalid("降级助手尚未取得有效 DUID，请在手机上联网检查更新后重试。") }
        self.serial = serial; duid = id
        model = DowngradeJSON.string(body,"model"); otaVersion = DowngradeJSON.string(body,"otaVersion"); project = DowngradeJSON.string(body,"prjNum")
        carrier = DowngradeJSON.string(body,"nvCarrier", fallback: "10010111")
        androidVersion = DowngradeJSON.string(body,"androidVersion", fallback: "Android15")
        colorOSVersion = DowngradeJSON.string(body,"colorosVersion", fallback: "ColorOS15.0.0")
        guard !serial.isEmpty, !model.isEmpty, !otaVersion.isEmpty, !project.isEmpty else { throw InputError.invalid("降级助手返回的机型、版本、项目号或序列号不完整。") }
    }
}

public struct DowngradePackage: Identifiable, Sendable, Equatable {
    public let id: Int
    public let otaVersion: String
    public let colorOSVersion: String
    public let androidVersion: String
    public let fileSize: UInt64
    public let md5: String
    public let url: URL
    public var fileExtension: String { ["zip","ozip"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "ozip" }
    public func sameContent(as other: DowngradePackage) -> Bool {
        otaVersion == other.otaVersion && colorOSVersion == other.colorOSVersion && androidVersion == other.androidVersion && fileSize == other.fileSize && md5 == other.md5
    }
    public func validateForInstall() throws {
        guard fileSize > 0, fileSize <= UInt64(Int64.max), md5.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              !otaVersion.isEmpty, !colorOSVersion.isEmpty else { throw InputError.invalid("降级包缺少有效的文件大小、MD5 或版本，不能执行推送安装。") }
    }
}

public struct DowngradeCatalog: Sendable {
    public let id: UUID
    public let device: DowngradeDeviceInfo
    public let packages: [DowngradePackage]
    public let created: Date
    fileprivate let metadata: String
    public func refreshedPackage(matching package: DowngradePackage) throws -> DowngradePackage {
        let matches = packages.filter { $0.sameContent(as: package) }
        guard matches.count == 1 else { throw InputError.invalid("重新查询后未找到唯一且大小 / MD5 / 版本一致的降级包，请重新选择。") }
        return matches[0]
    }
    fileprivate func installBody(package: DowngradePackage, remotePath: String) throws -> Data {
        try package.validateForInstall()
        guard packages.contains(package), !metadata.isEmpty else { throw InputError.invalid("降级包不属于当前服务端授权结果。") }
        return try DowngradeJSON.encode([
            "signData": metadata, "checkData":"deviceId:\(device.serial)userOtaVersion:\(device.otaVersion)",
            "versionName":package.otaVersion, "needDataSpace":package.fileSize,
            "components":[["componentId":"0", "componentName":package.otaVersion, "componentVersion":package.colorOSVersion,
                           "packageFullPath":try RemoteFiles.path(remotePath, allowRoot: false), "packetMd5":package.md5, "packetSize":package.fileSize]]
        ])
    }
}

public struct DowngradeClient: Sendable {
    public let endpoint: URL
    public init(endpoint: URL = URL(string: "https://downgrade.coloros.com/downgrade/query-v3")!) { self.endpoint = endpoint }
    public func query(_ info: DowngradeDeviceInfo) async throws -> DowngradeCatalog {
        _ = try HTTPClient.httpURL(endpoint.absoluteString)
        let key = try DowngradeCrypto.random(32), nonceData = try DowngradeCrypto.random(12)
        let sealed = try AES.GCM.seal(Data(info.duid.utf8), using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonceData))
        let protected = try DowngradeCrypto.protectKey(key.base64EncodedString())
        let cipherInfo = try DowngradeJSON.encode(["downgrade-server":["negotiationVersion":Int64(1636449646204), "protectedKey":protected.base64EncodedString(), "version":String(Int64(Date().timeIntervalSince1970))]])
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(decoding: cipherInfo, as: UTF8.self), forHTTPHeaderField: "cipherInfo")
        request.setValue(try DowngradeCrypto.random(16).map { String(format: "%02X",$0) }.joined(), forHTTPHeaderField: "deviceId")
        request.httpBody = try DowngradeJSON.encode([
            "androidVersion":info.androidVersion, "colorosVersion":info.colorOSVersion,
            "deviceId":["cipher":(sealed.ciphertext + sealed.tag).base64EncodedString(), "iv":nonceData.base64EncodedString()],
            "model":info.model, "nvCarrier":info.carrier, "otaVersion":info.otaVersion, "prjNum":info.project, "serialNo":info.serial
        ])
        let response = try DowngradeJSON.object(data: await HTTPClient.data(for: request))
        guard DowngradeJSON.integer(response["code"]) == 200, let data = response["data"] as? [String: Any] else { throw InputError.invalid("降级查询未成功，服务端状态：\(DowngradeJSON.integer(response["code"]).map(String.init) ?? "未知")。请联网检查更新后重试。") }
        guard let list = data["downgradeVoList"] as? [[String:Any]], list.count <= 512 else { throw InputError.invalid("降级查询的版本列表无效。") }
        let packages = try list.enumerated().map { index, item in
            DowngradePackage(id: index, otaVersion: DowngradeJSON.string(item,"otaVersion"), colorOSVersion: DowngradeJSON.string(item,"colorosVersion"), androidVersion: DowngradeJSON.string(item,"androidVersion"), fileSize: DowngradeJSON.unsigned(item["fileSize"]) ?? 0, md5: DowngradeJSON.string(item,"fileMd5").lowercased(), url: try HTTPClient.httpURL(DowngradeJSON.string(item,"downloadUrl")))
        }
        return DowngradeCatalog(id: UUID(), device: info, packages: packages, created: Date(), metadata: DowngradeJSON.string(data,"metaData"))
    }
}

public enum DowngradeAssistant {
    public static func deviceInfo(port: UInt16, serial: String, control: WorkControl) async throws -> DowngradeDeviceInfo {
        try await Task.detached {
            let socket = try AssistantSocket(port: port, control: control)
            try socket.authenticate()
            try socket.send(command: 40003, extra: socket.encrypt(Data("{}".utf8)))
            let response = try socket.receive(command: 30003)
            return try DowngradeDeviceInfo(DowngradeJSON.object(data: socket.decrypt(DowngradeJSON.string(response,"extraInfo"))), serial: serial)
        }.value
    }
    // Re-check the current assistant identity inside the very same authenticated
    // connection that receives the installation request. Once sent, await reply.
    public static func install(port: UInt16, catalog: DowngradeCatalog, package: DowngradePackage, remotePath: String, control: WorkControl) async throws -> Int {
        try await Task.detached {
            let socket = try AssistantSocket(port: port, control: control)
            try socket.authenticate()
            try socket.send(command: 40003, extra: socket.encrypt(Data("{}".utf8)))
            let response = try socket.receive(command: 30003)
            let actual = try DowngradeDeviceInfo(DowngradeJSON.object(data: socket.decrypt(DowngradeJSON.string(response,"extraInfo"))), serial: catalog.device.serial)
            guard actual == catalog.device else { throw InputError.invalid("安装前设备信息或当前版本发生变化，未发送安装请求。") }
            let body = try catalog.installBody(package: package, remotePath: remotePath)
            try control.check()
            try socket.send(command: 40006, extra: socket.encrypt(body), checkCancellation: false)
            let result = try socket.receive(command: nil, timeout: 300, checkCancellation: false)
            let decoded = result["verifyResult"] == nil ? try DowngradeJSON.object(data: socket.decrypt(DowngradeJSON.string(result,"extraInfo"))) : result
            guard let status = DowngradeJSON.integer(decoded["verifyResult"]) else { throw InputError.invalid("安装请求已发送，但助手未返回有效的 verifyResult，请在手机上确认状态。") }
            return status
        }.value
    }
}

private enum DowngradeJSON {
    static func object(data: Data) throws -> [String:Any] {
        guard data.count <= 4 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw InputError.invalid("降级助手 JSON 响应无效。") }
        return value
    }
    static func object(_ value: Any?) throws -> [String:Any] {
        if let value = value as? [String:Any] { return value }
        guard let string = value as? String else { throw InputError.invalid("降级助手缺少 JSON 对象。") }
        return try object(data: Data(string.utf8))
    }
    static func encode(_ object: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys,.withoutEscapingSlashes]) }
    static func string(_ value: [String:Any], _ key: String, fallback: String = "") -> String {
        guard let raw = value[key] as? String else { return fallback }
        return raw.isEmpty ? fallback : raw
    }
    static func integer(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        guard let value = value as? NSNumber else { return nil }; return Int(value.stringValue)
    }
    static func unsigned(_ value: Any?) -> UInt64? {
        if let value = value as? String { return UInt64(value) }
        guard let value = value as? NSNumber else { return nil }; return UInt64(value.stringValue)
    }
}

private enum DowngradeCrypto {
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault,count,$0.baseAddress!) }) == errSecSuccess else { throw InputError.invalid("系统随机数生成失败。") }
        return data
    }
    static func protectKey(_ value: String) throws -> Data {
        let base64 = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmeQzr0TIbtwZFnDXgatg6xP9SlNBFho1NTdFQ27SKDF+dBEEfnG9BqRw0na0DUqtpWe2CUtldbU33nnJ0KB6z7y5f+89o9n8mJxIbh952gpskBxyrhCfpYHV5mt/n9Tkm8OcQWLRFou7/XITuZeZejfUTesQjpfOeCaeKyVSoKQc6WuH7NSYq6B37RMyEn/1+vo8XuHEKD84p29KGpyGI7ZeL85iOcwBmOD6+e4yideH2RatA1SzEv/9V8BflaFLAWDuPWUjA2WgfOvy5spYmp/MoMOX4P0d+AkJ9Ms6PUXEUBsbOACmaMFyLCLHmd18+UeGdJR/3I15sXKbJhKerwIDAQAB"
        guard let der = Data(base64Encoded: base64) else { throw InputError.invalid("降级查询公钥编码无效。") }
        var outer = try AVBDER.contents(der)
        _ = try outer.read(0x30)
        let bits = try outer.read(0x03); try outer.finish()
        guard bits.first == 0 else { throw InputError.invalid("降级查询公钥格式无效。") }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData, [kSecAttrKeyType:kSecAttrKeyTypeRSA, kSecAttrKeyClass:kSecAttrKeyClassPublic] as CFDictionary, &error),
              let data = SecKeyCreateEncryptedData(key,.rsaEncryptionOAEPSHA1,Data(value.utf8) as CFData,&error) as Data? else { throw InputError.invalid("降级查询密钥加密失败。") }
        return data
    }
    static func ctr(_ input: Data, hash: String) throws -> Data {
        guard input.count <= 4 * 1024 * 1024, hash.utf8.count == 64 else { throw InputError.invalid("降级助手密文或会话密钥无效。") }
        if input.isEmpty { return Data() }
        let key = Data(hash.prefix(32).utf8), iv = Data(hash.suffix(16).utf8)
        var output = Data(count: input.count + 16), written = 0
        let status = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in input.withUnsafeBytes { input in output.withUnsafeMutableBytes { output in
            violet_aes256_ctr(key.bindMemory(to: UInt8.self).baseAddress,iv.bindMemory(to: UInt8.self).baseAddress,input.bindMemory(to: UInt8.self).baseAddress,input.count,output.bindMemory(to: UInt8.self).baseAddress,output.count,&written)
        } } } }
        guard status == 0, written == input.count else { throw InputError.invalid("降级助手 AES-CTR 处理失败。") }
        return Data(output.prefix(written))
    }
}

private final class AssistantSocket {
    private var descriptor: Int32
    private let control: WorkControl
    private var hash = ""
    init(port: UInt16, control: WorkControl) throws {
        guard port > 0 else { throw InputError.invalid("ADB 转发端口无效。") }
        self.control = control; descriptor = Darwin.socket(AF_INET,SOCK_STREAM,0)
        guard descriptor >= 0 else { throw InputError.invalid("无法创建降级助手连接。") }
        do {
            guard fcntl(descriptor,F_SETFL,O_NONBLOCK) == 0 else { throw InputError.invalid("无法配置降级助手连接。") }
            var noSignal: Int32 = 1
            guard setsockopt(descriptor,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw InputError.invalid("无法配置降级助手连接信号。") }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if status != 0 {
                guard errno == EINPROGRESS else { throw InputError.invalid("无法连接手机端降级助手，请确认 APK 已启动。") }
                try wait(POLLOUT, until: ProcessInfo.processInfo.systemUptime + 10, checkCancellation: true)
                var socketError: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor,SOL_SOCKET,SO_ERROR,&socketError,&size) == 0, socketError == 0 else { throw InputError.invalid("手机端降级助手未接受连接。") }
            }
        } catch { Darwin.close(descriptor); descriptor = -1; throw error }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    func authenticate() throws {
        let greeting = try receive(command: 30000)
        let info = try DowngradeJSON.object(greeting["extraInfo"])
        guard let pub = Data(base64Encoded: DowngradeJSON.string(info,"keyPair_pub")), pub.count <= 4096 else { throw InputError.invalid("降级助手公钥无效。") }
        let pair = P256.KeyAgreement.PrivateKey()
        let secret = try pair.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: pub))
        let encoded = secret.withUnsafeBytes { Data($0).base64EncodedString() }
        hash = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x",$0) }.joined()
        let publicKey = try DowngradeJSON.encode(["keyPair_pub":pair.publicKey.derRepresentation.base64EncodedString()])
        try send(command: 40000, extra: String(decoding: publicKey,as: UTF8.self))
        let keyResponse = try receive(command: 30001)
        _ = try decrypt(DowngradeJSON.string(keyResponse,"extraInfo"))
        let auth = P256.Signing.PrivateKey()
        let signingText = String(Int64(Date().timeIntervalSince1970 * 1000)) + String(try DowngradeCrypto.random(16).base64EncodedString().prefix(16))
        let signature = try auth.signature(for: Data(signingText.utf8))
        let body = try DowngradeJSON.encode(["verifyPass":true, "signData":signingText, "signValue":signature.derRepresentation.base64EncodedString(), "pubKey":auth.publicKey.derRepresentation.base64EncodedString()])
        try send(command: 40001, extra: encrypt(body))
        _ = try receive(command: 30002)
    }
    func encrypt(_ value: Data) throws -> String { try DowngradeCrypto.ctr(value,hash:hash).base64EncodedString() }
    func decrypt(_ value: String) throws -> Data {
        guard value.utf8.count <= 6 * 1024 * 1024, let data = Data(base64Encoded: value) else { throw InputError.invalid("降级助手密文 Base64 无效。") }
        return try DowngradeCrypto.ctr(data,hash:hash)
    }
    func send(command: Int, extra: String, checkCancellation: Bool = true) throws {
        let body = try DowngradeJSON.encode(["cmdId":command,"createTime":Int64(Date().timeIntervalSince1970 * 1000),"extraInfo":extra,"uuid":""])
        guard body.count <= 4 * 1024 * 1024 else { throw InputError.invalid("降级助手请求过大。") }
        var frame = Data("GhostPID".utf8)
        for (value,count) in [(UInt64(2),4),(UInt64(3000),4),(UInt64(body.count),8)] {
            for byte in (0..<count).reversed() { frame.append(UInt8(truncatingIfNeeded: value >> (byte*8))) }
        }
        frame += body
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var sent = 0
        while sent < frame.count {
            try wait(POLLOUT,until:deadline,checkCancellation:checkCancellation)
            let count = frame.withUnsafeBytes { Darwin.send(descriptor,$0.baseAddress!.advanced(by:sent),$0.count-sent,0) }
            if count < 0, [EINTR,EAGAIN,EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw InputError.invalid("降级助手连接在发送中断开。") }; sent += count
        }
    }
    func receive(command: Int?, timeout: Double = 10, checkCancellation: Bool = true) throws -> [String:Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let header = try read(24,until:deadline,checkCancellation:checkCancellation)
        guard header.prefix(8) == Data("GhostPID".utf8) else { throw InputError.invalid("降级助手响应帧签名无效。") }
        let length = try header.integer(at:16,bytes:8,bigEndian:true)
        guard length > 0, length <= 4 * 1024 * 1024 else { throw InputError.invalid("降级助手响应长度超出限制。") }
        let message = try DowngradeJSON.object(data: read(Int(length),until:deadline,checkCancellation:checkCancellation))
        if let command, DowngradeJSON.integer(message["cmdId"]) != command { throw InputError.invalid("降级助手未返回预期指令 \(command)。") }
        return message
    }
    private func read(_ length: Int, until deadline: Double, checkCancellation: Bool) throws -> Data {
        var data = Data(count: length), read = 0
        while read < length {
            try wait(POLLIN,until:deadline,checkCancellation:checkCancellation)
            let count = data.withUnsafeMutableBytes { Darwin.recv(descriptor,$0.baseAddress!.advanced(by:read),$0.count-read,0) }
            if count < 0, [EINTR,EAGAIN,EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw InputError.invalid("降级助手连接在接收中断开。若已发送安装请求，请在手机上确认状态。") }; read += count
        }
        return data
    }
    private func wait(_ events: Int32, until deadline: Double, checkCancellation: Bool) throws {
        while true {
            if checkCancellation { try control.check() }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw InputError.invalid("降级助手响应超时。若已发送安装请求，请在手机上确认状态。") }
            var item = pollfd(fd:descriptor,events:Int16(events),revents:0)
            let status = Darwin.poll(&item,1,Int32(min(100,max(1,remaining*1000))))
            if status < 0, errno == EINTR { continue }
            guard status >= 0 else { throw InputError.invalid("降级助手连接轮询失败。") }
            if status > 0 {
                if item.revents & Int16(events) != 0 { return }
                if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw InputError.invalid("降级助手连接已关闭。若已发送安装请求，请在手机上确认状态。") }
            }
        }
    }
}
