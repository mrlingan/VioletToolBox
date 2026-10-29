import Foundation

public struct ToolLocator: Sendable {
    public let customDirectory: String
    public let resourceDirectory: String?
    public init(customDirectory: String = "", resourceDirectory: String? = Bundle.main.resourcePath) {
        self.customDirectory = customDirectory
        self.resourceDirectory = resourceDirectory
    }
    public func locate(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [customDirectory,
            resourceDirectory.map { $0 + "/platform-tools" } ?? "",
            resourceDirectory.map { $0 + "/scrcpy" } ?? "",
            resourceDirectory.map { $0 + "/native-tools" } ?? "",
            resourceDirectory.map { $0 + "/edl-tools" } ?? "",
            "/opt/homebrew/bin", "/usr/local/bin", home + "/Library/Android/sdk/platform-tools"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return directories.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let adb = locate("adb") { paths.insert(adb.deletingLastPathComponent().path, at: 0); env["ADB"] = adb.path }
        env["PATH"] = paths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        return env
    }
}
