import Foundation
import CryptoKit
import VioletNative

public struct ModuleProperties: Sendable {
    public let values: [String: String]
    public var id: String { values["id"]! }
    public var name: String { values["name"] ?? id }
    public var version: String { values["version"] ?? "未知版本" }
    public static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
    public init(data: Data) throws {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw InputError.invalid("module.prop 必须是 64 KiB 以内的 UTF-8 文本。") }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            guard values[key] == nil else { throw InputError.invalid("module.prop 字段重复：\(key)") }
            values[key] = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let id = values["id"], Self.validID(id) else { throw InputError.invalid("模块 id 无效。") }
        self.values = values
    }
}

public struct ModulePackage: Identifiable, Sendable {
    public let sourceURL: URL
    public let properties: ModuleProperties
    public let sha256: String
    public var id: String { properties.id }
    private let snapshot: FileSnapshot
    public func validate() throws { try snapshot.validate() }
    public static func open(_ url: URL, control: WorkControl = WorkControl()) throws -> ModulePackage {
        try control.check()
        let snapshot = try FileSnapshot(url)
        guard snapshot.size <= 4 * 1024 * 1024 * 1024 else { throw InputError.invalid("模块 ZIP 超过 4 GiB 限制。") }
        var data = Data(count: 65536), count = 0, error = [CChar](repeating: 0, count: 1024)
        let status = data.withUnsafeMutableBytes { bytes in
            violet_module_prop(url.path, bytes.bindMemory(to: UInt8.self).baseAddress, 65536, &count, &error, error.count)
        }
        guard status == 0 else { throw InputError.invalid(String(cString: error)) }
        data.count = count
        let properties = try ModuleProperties(data: data), file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { try control.check(); hash.update(data: chunk) }
        try snapshot.validate(); try control.check()
        return ModulePackage(sourceURL: url, properties: properties, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), snapshot: snapshot)
    }
}

public struct RootManager: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case magisk = "Magisk", kernelSU = "KernelSU", apatch = "APatch" }
    public let kind: Kind
    public let binary: String
    public let version: String
    public var id: String { kind.rawValue }
    public init(kind: Kind, binary: String, version: String) throws {
        guard binary.hasPrefix("/"), binary.utf8.count <= 512,
              binary.range(of: "^/[A-Za-z0-9_./-]+$", options: .regularExpression) != nil,
              !binary.split(separator: "/").contains("..") else { throw InputError.invalid("Root 管理器路径无效。") }
        self.kind = kind; self.binary = binary; self.version = version
    }
    public func installScript(zip: String) -> String {
        Input.remoteQuote(binary) + (kind == .magisk ? " --install-module " : " module install ") + Input.remoteQuote(zip)
    }
}

public struct InstalledModule: Identifiable, Sendable {
    public let properties: ModuleProperties
    public let disabled: Bool
    public let removing: Bool
    public let updating: Bool
    public var id: String { properties.id }
}

public enum RootModuleCommands {
    public typealias Execute = @Sendable ([String], Double) async throws -> Void
    public static func install(_ packages: [ModulePackage], manager: RootManager, control: WorkControl,
                               execute: Execute, cleanup: Execute,
                               installed: @Sendable (String) -> Void = { _ in }) async throws {
        guard !packages.isEmpty, Set(packages.map(\.id)).count == packages.count else { throw InputError.invalid("模块清单为空或包含重复 id。") }
        for package in packages { try control.check(); try package.validate() }
        let temporary = "/data/local/tmp/violet-modules-" + UUID().uuidString
        do {
            try await execute(["shell", "umask 077; mkdir " + Input.remoteQuote(temporary)], 30)
            for (index, package) in packages.enumerated() {
                try control.check(); try package.validate()
                let remote = temporary + "/\(index).zip"
                try await execute(["push", package.sourceURL.path, remote], 600)
                try control.check(); try package.validate()
                try await execute(shell(manager.installScript(zip: remote)), 1800)
                installed(package.id)
                try control.check()
            }
        } catch {
            try? await cleanup(["shell", "rm -rf " + Input.remoteQuote(temporary)], 15)
            throw error
        }
        try await cleanup(["shell", "rm -rf " + Input.remoteQuote(temporary)], 15)
    }
    public static func shell(_ script: String) -> [String] { ["shell", "su -c " + Input.remoteQuote(script)] }
    public static let probe = """
    [ "$(id -u)" = 0 ] || exit 77
    printf 'VIOLET_ROOT_V1\\n'
    for pair in 'KernelSU:/data/adb/ksud' 'APatch:/data/adb/apd'; do
      kind=${pair%%:*}; bin=${pair#*:}
      if [ -x "$bin" ]; then
        ver=$("$bin" --version 2>/dev/null) || continue
        printf '%s\\t%s\\t' "$kind" "$bin"; printf '%s' "$ver" | base64 | tr -d '\\r\\n'; printf '\\n'
      fi
    done
    bin=$(command -v magisk)
    if [ -n "$bin" ]; then
      ver=$("$bin" -v 2>/dev/null) || exit 0
      printf 'Magisk\\t%s\\t' "$bin"; printf '%s' "$ver" | base64 | tr -d '\\r\\n'; printf '\\n'
    fi
    """
    public static func managers(_ text: String) throws -> [RootManager] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.first == "VIOLET_ROOT_V1", lines.count <= 4 else { throw InputError.invalid("Root 授权未通过或管理器响应无效。请在手机上允许 su 授权。") }
        var result: [RootManager] = []
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let kind = RootManager.Kind(rawValue: fields[0]),
                  let data = Data(base64Encoded: fields[2]), data.count <= 4096,
                  let version = String(data: data, encoding: .utf8), !result.contains(where: { $0.kind == kind }) else { throw InputError.invalid("Root 管理器响应格式错误。") }
            result.append(try RootManager(kind: kind, binary: fields[1], version: version))
        }
        return result
    }
    public static let list = """
    [ "$(id -u)" = 0 ] || exit 77
    printf 'VIOLET_MODULES_V1\\n'
    for dir in /data/adb/modules/*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      [ -f "$dir/module.prop" ] && [ ! -L "$dir/module.prop" ] || continue
      id=${dir##*/}; disabled=0; removing=0; updating=0
      [ -e "$dir/disable" ] && disabled=1
      [ -e "$dir/remove" ] && removing=1
      [ -d "/data/adb/modules_update/$id" ] && updating=1
      printf '%s\\t%s\\t%s\\t%s\\t' "$id" "$disabled" "$removing" "$updating"
      head -c 65537 "$dir/module.prop" | base64 | tr -d '\\r\\n'; printf '\\n'
    done
    """
    public static func modules(_ text: String) throws -> [InstalledModule] {
        guard text.utf8.count <= 48 * 1024 * 1024 else { throw InputError.invalid("模块列表过大。") }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.first == "VIOLET_MODULES_V1", lines.count <= 513 else { throw InputError.invalid("模块列表响应无效或超过 512 个模块。") }
        var modules: [InstalledModule] = []
        for line in lines.dropFirst() {
            let f = line.components(separatedBy: "\t")
            guard f.count == 5, ModuleProperties.validID(f[0]), f[1...3].allSatisfy({ $0 == "0" || $0 == "1" }),
                  let data = Data(base64Encoded: f[4]) else { throw InputError.invalid("模块列表字段无效。") }
            let properties = try ModuleProperties(data: data)
            guard properties.id == f[0], !modules.contains(where: { $0.id == properties.id }) else { throw InputError.invalid("模块目录与 id 不一致或重复。") }
            modules.append(InstalledModule(properties: properties, disabled: f[1] == "1", removing: f[2] == "1", updating: f[3] == "1"))
        }
        return modules.sorted { $0.id < $1.id }
    }
    public enum Action: String, Sendable { case enable = "启用", disable = "停用", remove = "标记卸载", undoRemove = "取消卸载" }
    public static func change(id: String, action: Action, manager: RootManager? = nil) throws -> String {
        guard ModuleProperties.validID(id) else { throw InputError.invalid("模块 id 无效。") }
        if let manager, manager.kind != .magisk {
            let verb: String
            switch action { case .enable: verb = "enable"; case .disable: verb = "disable"; case .remove: verb = "uninstall"; case .undoRemove: verb = "undo-uninstall" }
            return Input.remoteQuote(manager.binary) + " module " + verb + " " + Input.remoteQuote(id)
        }
        let directory = "/data/adb/modules/" + id
        let marker = directory + ((action == .remove || action == .undoRemove) ? "/remove" : "/disable")
        return "[ \"$(id -u)\" = 0 ] && [ -d \(Input.remoteQuote(directory)) ] && [ ! -L \(Input.remoteQuote(directory)) ] && [ ! -L \(Input.remoteQuote(marker)) ] && " +
            ((action == .disable || action == .remove) ? "touch " : "rm -f ") + Input.remoteQuote(marker)
    }
}
