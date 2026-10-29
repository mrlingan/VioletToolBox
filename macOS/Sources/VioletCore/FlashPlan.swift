import Foundation

/// Declarative fastboot operations. Imported scripts are parsed, never executed.
public struct FlashStep: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        case flash, erase, reboot, setActive, lock, createLogical, deleteLogical, resizeLogical, snapshotCancel, oem, requireFastbootd, cleanupCow, wipeData
    }
    public let operation: Operation
    public let target: String
    public let image: String?
    public let options: [String]
    public let size: UInt64?
    public let exactTarget: Bool?
    public let allowMissing: Bool?
    public init(_ operation: Operation, target: String = "", image: String? = nil, options: [String] = [], size: UInt64? = nil, exactTarget: Bool = false, allowMissing: Bool = false) {
        self.operation = operation; self.target = target; self.image = image; self.options = options; self.size = size
        self.exactTarget = exactTarget; self.allowMissing = allowMissing
    }
    public var summary: String { ([operation.rawValue, target] + options + (image.map { [$0] } ?? []) + (size.map { [String($0)] } ?? [])).filter { !$0.isEmpty }.joined(separator: " ") }
    public func arguments(imageURL: URL? = nil) throws -> [String] {
        switch operation {
        case .flash:
            guard let imageURL else { throw InputError.invalid("刷写镜像尚未准备。") }
            return options + ["flash", target, imageURL.path]
        case .erase: return ["erase", target]
        case .reboot: return target.isEmpty ? ["reboot"] : ["reboot", target]
        case .setActive: return ["set_active", target]
        case .lock: return [target == "oem" ? "oem" : "flashing", "lock"]
        case .createLogical, .resizeLogical:
            guard let size else { throw InputError.invalid("逻辑分区操作缺少大小。") }
            return [operation == .createLogical ? "create-logical-partition" : "resize-logical-partition", target, String(size)]
        case .deleteLogical: return ["delete-logical-partition", target]
        case .snapshotCancel: return ["snapshot-update", "cancel"]
        case .oem: return ["oem", target]
        case .requireFastbootd: return ["getvar","is-userspace"]
        case .cleanupCow: throw InputError.invalid("COW 清理需要执行器读取逻辑分区表。")
        case .wipeData: return ["-w"]
        }
    }
}

public struct FlashPlan: Sendable {
    public struct Document: Codable, Sendable {
        public let version: Int
        public let product: String?
        public let maximumAnti: UInt32?
        public let steps: [FlashStep]
        public init(product: String? = nil, maximumAnti: UInt32? = nil, steps: [FlashStep]) {
            version = 2; self.product = product; self.maximumAnti = maximumAnti; self.steps = steps
        }
    }
    public let root: URL
    public let document: Document
    public let issues: [String]
    public var canExecute: Bool { !document.steps.isEmpty && issues.isEmpty }
    private let snapshot: FileSnapshot?
    private let dependencies: [FileSnapshot]
    private init(root: URL, document: Document, issues: [String], snapshot: FileSnapshot? = nil, dependencies: [FileSnapshot] = []) throws {
        guard [1,2].contains(document.version), document.steps.count <= 16384, !document.steps.isEmpty else { throw InputError.invalid("线刷计划版本无效或没有操作。") }
        if let product = document.product {
            guard product.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else { throw InputError.invalid("机型代号无效。") }
        }
        var didTerminalReboot = false, didLock = false
        for step in document.steps {
            guard !didTerminalReboot else { throw InputError.invalid("系统 / Recovery 重启必须是计划的最后一步。") }
            if didLock, !(step.operation == .reboot && step.target.isEmpty) { throw InputError.invalid("回锁之后只允许最后重启系统，请将回锁放在全部写入之后。") }
            if ![FlashStep.Operation.createLogical,.resizeLogical].contains(step.operation), step.size != nil { throw InputError.invalid("此操作不接受分区大小字段。") }
            if step.exactTarget == true && ![FlashStep.Operation.flash,.erase].contains(step.operation) { throw InputError.invalid("此操作不接受命名分区精确目标选项。") }
            if step.allowMissing == true && step.operation != .deleteLogical { throw InputError.invalid("仅删除逻辑分区可接受不存在的目标。") }
            switch step.operation {
            case .flash, .erase:
                _ = try Input.partition(step.target)
                if step.operation == .flash {
                    guard let image = step.image, try ArchivePaths.normalize(image) == image,
                          step.options.allSatisfy({ ["--disable-verity", "--disable-verification"].contains($0) }), Set(step.options).count == step.options.count else { throw InputError.invalid("镜像路径或 Fastboot 参数无效。") }
                } else if step.image != nil || !step.options.isEmpty { throw InputError.invalid("擦除步骤参数无效。") }
            case .reboot:
                guard ["", "bootloader", "fastboot", "recovery"].contains(step.target), step.image == nil, step.options.isEmpty else { throw InputError.invalid("重启步骤无效。") }
                didTerminalReboot = ["","recovery"].contains(step.target)
            case .setActive:
                guard ["a","b"].contains(step.target), step.image == nil, step.options.isEmpty else { throw InputError.invalid("槽位步骤无效。") }
            case .lock:
                guard ["","oem"].contains(step.target), step.image == nil, step.options.isEmpty else { throw InputError.invalid("回锁步骤无效。") }
                didLock = true
            case .createLogical, .resizeLogical:
                _ = try Input.partition(step.target)
                guard let size = step.size, size <= UInt64(Int64.max), step.image == nil, step.options.isEmpty else { throw InputError.invalid("逻辑分区大小无效。") }
            case .deleteLogical:
                _ = try Input.partition(step.target)
                guard step.image == nil, step.options.isEmpty else { throw InputError.invalid("删除逻辑分区步骤无效。") }
            case .snapshotCancel, .requireFastbootd, .cleanupCow, .wipeData:
                guard step.target.isEmpty, step.image == nil, step.options.isEmpty else { throw InputError.invalid("快照取消步骤无效。") }
            case .oem:
                guard step.target == "cdms", step.image == nil, step.options.isEmpty else { throw InputError.invalid("尚不支持此 OEM 操作。") }
            }
        }
        self.root = root.standardizedFileURL; self.document = document; self.issues = issues; self.snapshot = snapshot; self.dependencies = dependencies
    }
    public static func create(root: URL, product: String? = nil, maximumAnti: UInt32? = nil, steps: [FlashStep]) throws -> FlashPlan {
        try FlashPlan(root: root, document: Document(product: product, maximumAnti: maximumAnti, steps: steps), issues: [])
    }
    public func validate() throws {
        try snapshot?.validate()
        for dependency in dependencies { try dependency.validate() }
        guard canExecute else { throw InputError.invalid("脚本含未支持语句，不能执行；请核对诊断。") }
    }
    public func replacingSteps(_ steps: [FlashStep]) throws -> FlashPlan {
        try validate()
        return try FlashPlan(root: root, document: Document(product: document.product, maximumAnti: document.maximumAnti, steps: steps), issues: issues, snapshot: snapshot, dependencies: dependencies)
    }
    public func imageURL(_ relative: String) throws -> URL {
        guard try ArchivePaths.normalize(relative) == relative else { throw InputError.invalid("镜像路径无效。") }
        let actualRoot = root.resolvingSymlinksInPath(), actual = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard actual.path.hasPrefix(actualRoot.path + "/") else { throw InputError.invalid("镜像指向包目录之外：\(relative)") }
        _ = try FileSnapshot(actual)
        return actual
    }
    public static func scan(_ root: URL, excludeSensitive: Bool = true) throws -> FlashPlan {
        let sensitive: Set<String> = ["persist","ocdt","fsc","fsg","modemst1","modemst2","persistbak"]
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { ["img","bin"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let steps = files.compactMap { file -> FlashStep? in
            let name = file.deletingPathExtension().lastPathComponent
            guard !excludeSensitive || !sensitive.contains(PartitionCommands.withoutSlot(name).lowercased()) else { return nil }
            return FlashStep(.flash, target: name, image: file.lastPathComponent)
        }
        return try create(root: root, steps: steps)
    }
    public func exportJSON(to destination: URL) throws -> URL {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try AtomicOutput(destination); try output.handle.write(contentsOf: encoder.encode(document)); return try output.commit()
    }

    public static func open(_ file: URL) throws -> FlashPlan {
        let snapshot = try FileSnapshot(file)
        guard snapshot.size <= 4 * 1024 * 1024 else { throw InputError.invalid("脚本超过 4 MiB。") }
        let data = try Data(contentsOf: file), root = file.deletingLastPathComponent()
        let result: FlashPlan
        if file.pathExtension.lowercased() == "json" {
            result = try FlashPlan(root: root, document: JSONDecoder().decode(Document.self, from: data), issues: [], snapshot: snapshot)
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw InputError.invalid("请将脚本转换为 UTF-8 后导入。") }
            result = try parse(text, root: root, windows: file.pathExtension.lowercased() == "bat", snapshot: snapshot)
        }
        try snapshot.validate(); return result
    }
    public static func parse(_ text: String, root: URL, windows: Bool) throws -> FlashPlan {
        try parse(text, root: root, windows: windows, snapshot: nil)
    }
    private static func parse(_ text: String, root: URL, windows: Bool, snapshot: FileSnapshot?) throws -> FlashPlan {
        let guards = windows ? try XiaomiBatchGuards.translate(text, root: root) : XiaomiBatchGuards.Result(text: text)
        var steps: [FlashStep] = [], issues: [String] = [], product = guards.product
        for (index, raw) in guards.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 { line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) }
            if windows && line.hasPrefix("@") { line.removeFirst() }
            let lower = line.lowercased()
            if line.isEmpty || line.hasPrefix("#") || lower.hasPrefix("rem ") || line.hasPrefix("::") || ["echo off","set -e","set -eu","set -euo pipefail","pause"].contains(lower) { continue }
            if lower.hasPrefix("echo ") || lower.hasPrefix("echo.") || lower == "echo" {
                if !line.contains(where: { "&|<>`;".contains($0) }), !line.contains("$("), !line.contains("%") { continue }
            }
            if lower == "chcp 65001>nul" || lower == "chcp 65001 >nul" { continue }
            // Only this complete, known product guard is translated. Unknown
            // conditionals, anti rollback blocks and labels remain diagnostics.
            let productPattern = #"^(?:fastboot(?:\.exe)?)(?: %\*)? getvar product 2>&1 \| findstr /r /c:"\^product: \*([A-Za-z0-9_.-]+)" \|\| exit /[bB] 1$"#
            if windows, let value = capture(productPattern, line) {
                if let product, product != value { issues.append("第 \(index+1) 行：机型检查冲突。") }
                product = value; continue
            }
            // A failure tail is supported only when its complete meaning is
            // stop-on-error. Shell operators elsewhere are never stripped.
            if windows, let range = line.range(of: #"\s+\|\|\s+exit /[bB] 1$"#, options: .regularExpression) { line.removeSubrange(range) }
            if !windows, let range = line.range(of: #"\s+\|\|\s+exit (?:1|\$\?)$"#, options: .regularExpression) { line.removeSubrange(range) }
            do {
                guard !line.contains(where: { "&|<>`;".contains($0) }), !line.contains("$("), !line.contains("${") else { throw InputError.invalid("含控制流或 Shell 运算符") }
                var args = try tokens(line, windows: windows)
                guard !args.isEmpty, ["fastboot","fastboot.exe","./fastboot"].contains(args.removeFirst().lowercased()) else { throw InputError.invalid("非 Fastboot 语句") }
                if windows && args.first == "%*" { args.removeFirst() }
                var options: [String] = []
                while let arg = args.first, ["--disable-verity","--disable-verification"].contains(arg) { options.append(args.removeFirst()) }
                guard let command = args.first else { throw InputError.invalid("缺少命令") }
                args.removeFirst()
                switch command {
                case "flash":
                    guard args.count == 2 else { throw InputError.invalid("flash 参数不完整或含未支持选项") }
                    var path = args[1]
                    if windows { path = path.replacingOccurrences(of: "%~dp0", with: "").replacingOccurrences(of: "\\", with: "/") }
                    while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
                    guard !path.contains("%"), !path.contains("$") else { throw InputError.invalid("未支持的路径变量") }
                    let target = args[0]
                    if target.hasSuffix("_ab") {
                        for slot in ["a","b"] { steps.append(FlashStep(.flash, target: String(target.dropLast(3)) + "_" + slot, image: path, options: options)) }
                    } else { steps.append(FlashStep(.flash, target: target, image: path, options: options)) }
                case "erase":
                    guard args.count == 1, options.isEmpty else { throw InputError.invalid("erase 参数无效") }
                    steps.append(FlashStep(.erase, target: args[0]))
                case "reboot":
                    guard args.count <= 1, options.isEmpty else { throw InputError.invalid("reboot 参数无效") }
                    steps.append(FlashStep(.reboot, target: args.first ?? ""))
                case "set_active":
                    guard args.count == 1, options.isEmpty else { throw InputError.invalid("set_active 参数无效") }
                    steps.append(FlashStep(.setActive, target: args[0].hasPrefix("_") ? String(args[0].dropFirst()) : args[0]))
                case "flashing":
                    guard args == ["lock"], options.isEmpty else { throw InputError.invalid("未支持的 flashing 命令") }
                    steps.append(FlashStep(.lock))
                case "create-logical-partition", "resize-logical-partition":
                    guard args.count == 2, options.isEmpty, let size = UInt64(args[1]) else { throw InputError.invalid("逻辑分区参数无效") }
                    steps.append(FlashStep(command == "create-logical-partition" ? .createLogical : .resizeLogical, target: args[0], size: size))
                case "delete-logical-partition":
                    guard args.count == 1, options.isEmpty else { throw InputError.invalid("删除逻辑分区参数无效") }
                    steps.append(FlashStep(.deleteLogical, target: args[0]))
                case "snapshot-update":
                    guard args == ["cancel"], options.isEmpty else { throw InputError.invalid("快照操作参数无效") }
                    steps.append(FlashStep(.snapshotCancel))
                case "oem":
                    guard args.count == 1, options.isEmpty else { throw InputError.invalid("OEM 参数无效") }
                    if args[0] == "lock" { steps.append(FlashStep(.lock, target: "oem")) }
                    else if args[0] == "cdms" { steps.append(FlashStep(.oem, target: "cdms")) }
                    else { throw InputError.invalid("尚不支持此 OEM 操作") }
                case "-w":
                    guard args.isEmpty, options.isEmpty else { throw InputError.invalid("清数据命令参数无效") }
                    steps.append(FlashStep(.wipeData))
                default: throw InputError.invalid("未支持命令 \(command)")
                }
            } catch { issues.append("第 \(index+1) 行：\(error.localizedDescription) · \(raw.prefix(200))") }
        }
        return try FlashPlan(root: root, document: Document(product: product, maximumAnti: guards.maximumAnti, steps: steps), issues: issues, snapshot: snapshot, dependencies: guards.dependencies)
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func tokens(_ line: String, windows: Bool) throws -> [String] {
        if !windows { return try Input.arguments(line) }
        var result: [String] = [], word = "", quoted = false, started = false
        for char in line {
            if char == "\"" { quoted.toggle(); started = true }
            else if char.isWhitespace && !quoted { if started { result.append(word); word = ""; started = false } }
            else { word.append(char); started = true }
        }
        guard !quoted else { throw InputError.invalid("引号不完整") }
        if started { result.append(word) }; return result
    }

    /// Fastboot writes getvar to stderr on many versions. Reject ambiguous or
    /// missing values instead of interpreting an error message as a result.
    public static func variable(_ name: String, from text: String) throws -> String {
        var values: Set<String> = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["(bootloader)","INFO"] { if line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) } }
            if line.hasPrefix(name + ":") { values.insert(String(line.dropFirst(name.count+1)).trimmingCharacters(in: .whitespaces)) }
        }
        guard values.count == 1, let value = values.first, !value.isEmpty else { throw InputError.invalid("设备未返回唯一的 \(name)。") }
        return value
    }
    public func checkRequirements(product: String?, anti: String?) throws {
        if let expected = document.product, product != expected { throw InputError.invalid("机型不符：计划要求 \(expected)，设备返回 \(product ?? "未知")。") }
        if let maximum = document.maximumAnti {
            guard let anti, let value = UInt32(anti), value <= maximum else { throw InputError.invalid("防回滚检查未通过：设备 anti=\(anti ?? "未知")，包允许上限 \(maximum)。") }
        }
    }
}
