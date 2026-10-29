import Foundation

public struct Device: Identifiable, Hashable, Sendable {
    public enum Transport: String, Sendable { case adb, fastboot }
    public let serial: String
    public let state: String
    public let model: String
    public let transport: Transport
    public var id: String { "\(transport.rawValue):\(serial)" }
    public var ready: Bool { transport == .fastboot || ["device", "recovery", "sideload"].contains(state) }
    public var shellReady: Bool { transport == .adb && ["device", "recovery"].contains(state) }
    public var label: String { model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ") }
    public var statusLabel: String {
        switch state {
        case "device": return "ADB 已连接"
        case "unauthorized": return "请在手机上允许 USB 调试"
        case "offline": return "设备离线，请重新连接"
        case "fastboot": return "Fastboot"
        case "recovery": return "Recovery"
        case "sideload": return "ADB Sideload"
        default: return state
        }
    }

    public static func parseADB(_ output: String) -> [Device] {
        output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List "), !line.hasPrefix("*"),
                  ["device", "recovery", "sideload", "unauthorized", "offline", "no"].contains(parts[1]) else { return nil }
            let model = parts.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
            return Device(serial: parts[0], state: parts[1], model: model, transport: .adb)
        }
    }

    public static func parseFastboot(_ output: String) -> [Device] {
        output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] == "fastboot" else { return nil }
            return Device(serial: String(parts[0]), state: "fastboot", model: "", transport: .fastboot)
        }
    }

    public static func properties(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard line.hasPrefix("["), let split = line.range(of: "]: ["), line.hasSuffix("]") else { continue }
            values[String(line[line.index(after: line.startIndex)..<split.lowerBound])] = String(line[split.upperBound..<line.index(before: line.endIndex)])
        }
        return values
    }
}

public enum InputError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public enum Input {
    // ADB joins shell arguments on the remote side: quote paths for Android's shell too.
    public static func remoteQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func partition(_ value: String) throws -> String {
        guard !value.isEmpty, value.range(of: "^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil else {
            throw InputError.invalid("分区名只能包含字母、数字、下划线、点和连字符。")
        }
        return value
    }
    public static func package(_ value: String) throws -> String {
        guard value.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$", options: .regularExpression) != nil else {
            throw InputError.invalid("请输入有效的 Android 应用包名。")
        }
        return value
    }
    public static func endpoint(_ value: String) throws -> String {
        guard value.range(of: "^(?:[A-Za-z0-9][A-Za-z0-9.-]*|\\[[0-9A-Fa-f:]+\\]):[0-9]{1,5}$", options: .regularExpression) != nil,
              let port = Int(value.split(separator: ":").last ?? ""), (1...65535).contains(port) else {
            throw InputError.invalid("请输入 主机:端口，例如 192.168.1.20:37123。")
        }
        return value
    }
    public static func arguments(_ line: String) throws -> [String] {
        var args: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for char in line {
            if escaped { word.append(char); escaped = false; started = true; continue }
            if char == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { word.append(char) }
                continue
            }
            if char == "\"" || char == "'" { quote = char; started = true }
            else if char.isWhitespace { if started { args.append(word); word = ""; started = false } }
            else { word.append(char); started = true }
        }
        guard quote == nil, !escaped else { throw InputError.invalid("引号或转义符不完整。") }
        if started { args.append(word) }
        return args
    }

    public static func deviceArguments(_ line: String, tool: String) throws -> [String] {
        let args = try arguments(line)
        guard let command = args.first, !command.hasPrefix("-"), command != "adb", command != "fastboot" else {
            throw InputError.invalid("请填写工具名之后的设备命令，不要添加连接选项。")
        }
        let targetOptions = ["-s", "-t", "-H", "-P", "-L"]
        let longOptions = ["--serial", "--transport-id", "--one-device"]
        // ADB shell's trailing arguments belong to the remote command. Fastboot
        // accepts global options after its command, so validate its entire line.
        let options = tool == "adb" ? Array(args.prefix(1)) : args
        guard !options.contains(where: { value in
            targetOptions.contains(where: { value.hasPrefix($0) }) ||
            longOptions.contains(where: { value == $0 || value.hasPrefix($0 + "=") }) ||
            ["-d", "-e"].contains(value)
        }) else { throw InputError.invalid("请使用上方设备选择器指定设备，勿覆盖连接目标。") }
        if tool == "adb", ["devices", "connect", "disconnect", "pair", "kill-server", "start-server", "server-status", "reconnect", "tcpip", "usb"].contains(command) {
            throw InputError.invalid("此命令会修改或查询连接状态。请使用「工具与设置」管理连接。")
        }
        return args
    }
}
