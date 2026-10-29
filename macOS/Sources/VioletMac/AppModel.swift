import AppKit
import SwiftUI
import VioletCore
import UniformTypeIdentifiers

struct PendingOperation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let action: () -> Void
}

@MainActor final class AppModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedID = ""
    @Published var properties: [String: String] = [:]
    @Published var busy = false
    @Published var cancellationAtBoundary = false
    @Published var refreshing = false
    @Published var activity = "就绪"
    @Published var log = "欢迎使用紫罗兰工具箱 macOS 版。\n连接 Android 设备，并在手机上允许 USB 调试。\n"
    @Published var packages: [String] = []
    @Published var devicePartitions: [DevicePartition] = []
    @Published var partitionDeviceID = ""
    @Published var partitionImages: [String: URL] = [:]
    @Published var flashPlan: FlashPlan?
    @Published var rawProgramImages: RawProgramImages?
    @Published var oujiaPackage: OujiaPackage?
    @Published var xblARB: XBLARBImage?
    @Published var xblARBSource = ""
    @Published var edlDevices: [EDLUSBDevice] = []
    @Published var selectedEDLDeviceID = ""
    @Published var edlLoader: EDLLoader?
    @Published var edlContext: EDLContext?
    @Published var edlGeometries: [EDLGeometry] = []
    @Published var edlVolumes: [EDLVolume] = []
    @Published var edlImages: [String: URL] = [:]
    @Published var edlLastFailure = ""
    @Published var edlChipInfo = ""
    @Published var edlSlot = ""
    @Published var edlRestoreVolume: EDLVolume?
    @Published var edlFlashPackage: EDLFlashPackage?
    @Published var edlFlashPackageRevision = UUID()
    @Published var localGPT: GPTDiskImage?
    @Published var localGPTURL: URL?
    @Published var remoteFiles: [RemoteFile] = []
    @Published var remoteDirectory = "/sdcard"
    @Published var error: String?
    @Published var pending: PendingOperation?
    @Published var toolsVersion = ""
    @Published var mirroring = false
    @Published var payload: PayloadArchive?
    @Published var remoteFirmwareSource = ""
    @Published var remoteFirmwareHeaders: [String:String] = [:]
    @Published var remoteFirmware: RemoteFirmwareArchive?
    @Published var localFirmwareVersion: FirmwareVersionDetails?
    @Published var localFirmwareVersionSource = ""
    @Published var firmwarePackage: FirmwarePackage?
    @Published var sparseImage: SparseImage?
    @Published var bootImage: BootImage?
    @Published var ocdtImage: OCDTImage?
    @Published var avbImage: AVBImage?
    @Published var avbResult = ""
    @Published var avbBindings: [String: URL] = [:]
    @Published var modulePackages: [ModulePackage] = []
    @Published var rootManagers: [RootManager] = []
    @Published var rootManagerID = ""
    @Published var rootDeviceID = ""
    @Published var installedModules: [InstalledModule] = []
    @Published var superFiles: [URL] = []
    @Published var superVariants: [SuperVariant] = []
    @Published var superVariantID = ""
    @Published var workProgress: WorkProgress?
    @Published var downloadSource = ""
    @Published var downloadDestination: URL?
    @Published var downloadHeaders: [String: String] = [:]
    @Published var romSelection = ROMSelection()
    @Published var romSeries: [String] = []
    @Published var romDevices: [String] = []
    @Published var romVersions: [String] = []
    @Published var romLinks: ROMLinks?
    @Published var lenovoROM: LenovoROMResult?
    @Published var downgradeAPK: URL?
    @Published var downgradeLocalPackage: URL?
    @Published var downgradeCatalog: DowngradeCatalog?
    @Published var downgradeDevice: Device?
    @Published var downgradeVersion: FirmwareVersionDetails?
    @Published var downgradeVersionPackage: Int?
    let downloadService = ResumableDownload()
    var workControl = WorkControl()
    private var operationTask: Task<Void, Never>?
    @Published var customDirectory = UserDefaults.standard.string(forKey: "toolsDirectory") ?? ""
    private let runner = CommandRunner()
    private let discovery = CommandRunner()
    private let mirrorRunner = CommandRunner()
    private var lastDetailID = ""
    private var generation = 0
    private var cancelRequested = false
    var locator: ToolLocator { ToolLocator(customDirectory: customDirectory) }
    var selected: Device? { devices.first { $0.id == selectedID } }
    var adbReady: Bool { selected?.shellReady == true }
    var fastbootReady: Bool { selected?.transport == .fastboot }

    func append(_ message: String) {
        log += "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
        if log.count > 160_000 { log = String(log.suffix(120_000)) }
    }

    func selectionChanged() {
        generation += 1; properties = [:]; packages = []; lastDetailID = ""
        downgradeCatalog = nil; downgradeDevice = nil
        downgradeVersion = nil; downgradeVersionPackage = nil
        rootManagers = []; rootManagerID = ""; rootDeviceID = ""; installedModules = []
        remoteFiles = []; remoteDirectory = "/sdcard"
        devicePartitions = []; partitionDeviceID = ""; partitionImages = [:]
    }

    func refresh(force: Bool = false) async {
        guard !refreshing, !busy else { return }
        refreshing = true
        defer { refreshing = false }
        let oldID = selectedID
        var found: [Device] = []
        for tool in ["adb", "fastboot"] {
            guard let url = locator.locate(tool) else { continue }
            do {
                let result = try await discovery.run(executable: url, arguments: tool == "adb" ? ["devices", "-l"] : ["devices"], environment: locator.environment, timeout: 8)
                if result.succeeded { found += tool == "adb" ? Device.parseADB(result.stdout) : Device.parseFastboot(result.stdout) }
                else if force { append("\(tool) 设备扫描失败：\(result.text)") }
            } catch { if force { append(error.localizedDescription) } }
        }
        guard !busy else { return }
        devices = found
        // Do not silently select a different phone after the current phone disconnects.
        if oldID.isEmpty, found.count == 1 { selectedID = found[0].id }
        if !found.contains(where: { $0.id == selectedID }) { properties = [:]; packages = []; lastDetailID = "" }
        guard let device = selected, device.shellReady, force || lastDetailID != device.id else { return }
        let token = generation
        if let url = locator.locate("adb"), let result = try? await discovery.run(executable: url, arguments: ["-s", device.serial, "shell", "getprop"], environment: locator.environment, timeout: 8), result.succeeded,
           token == generation, selectedID == device.id, !busy {
            properties = Device.properties(result.stdout); lastDetailID = device.id
        }
    }

    @discardableResult func execute(_ tool: String, _ args: [String], device: Device? = nil,
                                   global: Bool = false, timeout: Double = 120,
                                   binary: Bool = false, input: Data? = nil, rawOutput: Bool = false) async throws -> CommandResult {
        guard !cancelRequested else { throw InputError.invalid("命令已取消，后续步骤已停止。") }
        guard let url = locator.locate(tool) else { throw InputError.invalid("找不到 \(tool)。请前往「工具与设置」指定工具目录。") }
        var actual = args
        if !global {
            guard let device = device ?? selected, device.ready, device.transport.rawValue == tool else {
                throw InputError.invalid("请先选择处于 \(tool) 模式且已授权的设备。")
            }
            actual = ["-s", device.serial] + args
        }
        // Pairing codes are passed via stdin and never recorded in logs.
        append("$ \(tool) " + actual.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        let result = try await runner.run(executable: url, arguments: actual, environment: locator.environment, timeout: timeout, input: input, captureText: !rawOutput)
        if !binary, !result.text.isEmpty { append(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if !result.succeeded {
            let reason = result.cancelled ? "命令已取消" : result.timedOut ? "命令超时，已停止" : "命令失败（退出码 \(result.status)）"
            throw InputError.invalid(reason + (result.stderr.isEmpty ? "" : "\n" + String(result.stderr.suffix(3000))))
        }
        return result
    }

    func perform(_ title: String, stopAtBoundary: Bool = false, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        cancelRequested = false; cancellationAtBoundary = stopAtBoundary; workControl = WorkControl(); workProgress = nil; busy = true; activity = title
        operationTask = Task {
            defer { busy = false; cancellationAtBoundary = false; activity = "就绪"; workProgress = nil; operationTask = nil }
            do { try await work(); append("\(title)完成") }
            catch {
                if cancelRequested || Task.isCancelled || error is CancellationError {
                    append(stopAtBoundary ? "操作已停止，设备上已执行的更改不会回滚。" : "操作已停止，已完成的输出和下载片段会保留。")
                }
                else { append(error.localizedDescription); self.error = error.localizedDescription }
            }
        }
    }

    func executeHost(_ tool: String, args: [String], directory: URL, environment: [String: String]) async throws -> CommandResult {
        guard !cancelRequested else { throw CancellationError() }
        guard ["magiskboot","kptools","ksud"].contains(tool), let url = locator.locate(tool) else { throw InputError.invalid("找不到 macOS 原生 \(tool)，请配置工具目录。") }
        append("$ \(tool) " + args.map { Input.remoteQuote($0) }.joined(separator: " "))
        let result = try await runner.run(executable: url, arguments: args, environment: locator.environment.merging(environment) { _, new in new }, timeout: 600, workingDirectory: directory)
        if !result.text.isEmpty { append(String(result.text.suffix(6000))) }
        return result
    }

    func executeEDLTool(_ tool: String, args: [String], timeout: Double = 3600) async throws -> CommandResult {
        guard !cancelRequested else { throw CancellationError() }
        guard ["qdl","violet-edl"].contains(tool), let executable = locator.locate(tool) else { throw InputError.invalid("缺少 macOS 原生 \(tool)，请配置 EDL 工具目录。") }
        append("$ \(tool) " + args.map(Input.remoteQuote).joined(separator: " "))
        let control = workControl
        do {
            let result = try await runner.run(executable: executable, arguments: args, environment: locator.environment, timeout: timeout, stderrLine: { line in
                let fields = line.components(separatedBy: "\t")
                if fields.count == 3, fields[0] == "VIOLET_EDL_PROGRESS", let done = UInt64(fields[1]), let total = UInt64(fields[2]), done <= total {
                    Task { @MainActor in self.reportWork(WorkProgress("EDL 数据传输", done: done, total: total), control: control) }
                }
            })
            append(String(result.text.suffix(6000)))
            guard result.succeeded else { throw InputError.invalid("EDL 命令未成功（\(result.status)\(result.timedOut ? ", timeout" : "")）：\(result.text.suffix(3000))") }
            return result
        } catch {
            if tool == "violet-edl" { edlLastFailure = error.localizedDescription; edlContext = nil }
            throw error
        }
    }

    func command(_ title: String, tool: String = "adb", args: [String], destructive: Bool = false, detail: String = "") {
        guard let device = selected else { return }
        let action = { [self] in
            perform(title) { _ = try await self.execute(tool, args, device: device, timeout: 3600) }
        }
        if destructive {
            pending = PendingOperation(title: title, detail: "设备：\(device.label)\n序列号：\(device.serial)\n命令：\(tool) \(args.joined(separator: " "))\n\n\(detail)", action: action)
        } else { action() }
    }

    func cancel() {
        cancelRequested = true; workControl.cancel()
        if cancellationAtBoundary {
            activity = "已请求停止，等待当前命令结束"
            append("已请求停止后续步骤；当前设备命令完成后结束。")
            return
        }
        operationTask?.cancel()
        Task { await runner.cancel(); await downloadService.cancel() }
    }

    func executeStream(_ args: [String], device: Device, to target: URL, expectedSize: UInt64) async throws -> URL {
        guard !cancelRequested else { throw CancellationError() }
        guard device.shellReady, let adb = locator.locate("adb") else { throw InputError.invalid("请选择可用 ADB 设备并配置 adb。") }
        append("$ adb -s \(device.serial) " + args.map { Input.remoteQuote($0) }.joined(separator: " "))
        let control = workControl
        let result = try await runner.stream(executable: adb, arguments: ["-s",device.serial] + args, to: target, expectedSize: expectedSize, environment: locator.environment) { progress in
            Task { @MainActor in self.reportWork(progress, control: control) }
        }
        if !result.stderr.isEmpty { append(result.stderr) }
        append("已回读 \(result.size) bytes：\(result.url.path)")
        return result.url
    }

    func startMirror(size: String, fps: String, noAudio: Bool, stayAwake: Bool) {
        guard !mirroring, let device = selected, device.shellReady else { return }
        guard let url = locator.locate("scrcpy") else { error = "请安装 scrcpy，或在工具目录中提供可执行文件。"; return }
        var args = ["--serial", device.serial, "--window-title", "紫罗兰 · " + device.label, "--max-size", size, "--max-fps", fps]
        if noAudio { args.append("--no-audio") }
        if stayAwake { args.append("--stay-awake") }
        let environment = locator.environment
        mirroring = true
        append("启动 scrcpy · \(device.serial)")
        Task {
            defer { mirroring = false }
            do {
                let result = try await mirrorRunner.run(executable: url, arguments: args, environment: environment, timeout: 86400)
                append(result.text)
                if !result.succeeded && !result.cancelled { error = "投屏已退出：\(result.text.suffix(2000))" }
            } catch { self.error = error.localizedDescription }
        }
    }

    func stopMirror() { Task { await mirrorRunner.cancel() } }

    func shutdown() async {
        cancelRequested = true
        workControl.cancel()
        let operation = operationTask
        operation?.cancel()
        await downloadService.cancel()
        await runner.cancelAndWait()
        await mirrorRunner.cancelAndWait()
        await discovery.cancelAndWait()
        await operation?.value
        payload?.cleanup()
    }

    func chooseFiles(extensions: [String] = [], multiple: Bool = false, directories: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories; panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = multiple
        if !extensions.isEmpty { panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) } }
        return panel.runModal() == .OK ? panel.urls : []
    }

    func saveURL(name: String) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    func screenshot() {
        guard let device = selected, let destination = saveURL(name: "Screenshot-\(Int(Date().timeIntervalSince1970)).png") else { return }
        perform("截取屏幕") {
            let result = try await self.execute("adb", ["exec-out", "screencap", "-p"], device: device, binary: true)
            guard result.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw InputError.invalid("设备未返回有效 PNG 图片。") }
            try result.data.write(to: destination, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func installAPKs() {
        guard let device = selected else { return }
        let files = chooseFiles(extensions: ["apk"], multiple: true)
        guard !files.isEmpty else { return }
        perform("安装 APK") {
            for file in files { _ = try await self.execute("adb", ["install", "-r", file.path], device: device, timeout: 600) }
        }
    }

    func loadPackages(thirdParty: Bool, disabledOnly: Bool = false) {
        guard let device = selected else { return }
        perform("读取应用列表") {
            let result = try await self.execute("adb", ["shell", "pm", "list", "packages"] + (thirdParty ? ["-3"] : []) + (disabledOnly ? ["-d"] : []), device: device)
            if self.selectedID == device.id {
                self.packages = result.stdout.components(separatedBy: .newlines).filter { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) }.sorted()
            }
        }
    }

    func extractAPK(_ package: String) {
        extractAPKs([package])
    }

    func extractAPKs(_ packages: [String]) {
        guard let device = selected, !packages.isEmpty, let folder = chooseFiles(directories: true).first else { return }
        let target = folder.appendingPathComponent("VioletAPKs-" + UUID().uuidString.prefix(8))
        perform("提取 APK") {
            let names = try packages.map { try Input.package($0) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for name in names {
                let result = try await self.execute("adb", ["shell", "pm", "path", name], device: device)
                let paths = result.stdout.components(separatedBy: .newlines).filter { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !paths.isEmpty else { throw InputError.invalid("未找到 \(name) 的 APK 路径。") }
                let destination = target.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                for (index, path) in paths.enumerated() {
                    _ = try RemoteFiles.path(path, allowRoot: false)
                    _ = try await self.execute("adb", ["pull", path, destination.appendingPathComponent("\(index)-" + URL(fileURLWithPath: path).lastPathComponent).path], device: device, timeout: 600)
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func transfer(push: Bool, remote: String) {
        guard let device = selected else { return }
        let path = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { error = "请输入设备上的绝对路径。"; return }
        let files = chooseFiles(multiple: push, directories: !push)
        guard !files.isEmpty else { return }
        perform(push ? "发送文件" : "接收文件") {
            if push {
                for file in files { _ = try await self.execute("adb", ["push", file.path, path], device: device, timeout: 3600) }
            } else {
                _ = try await self.execute("adb", ["pull", path, files[0].path], device: device, timeout: 3600)
            }
        }
    }

    func flash(partition: String, image: URL?, slot: String, temporary: Bool) {
        guard let image else { error = "请先选择镜像文件。"; return }
        do {
            let name = try Input.partition(partition)
            guard FileManager.default.isReadableFile(atPath: image.path) else { throw InputError.invalid("镜像文件不可读。") }
            let args = temporary ? ["boot", image.path] : (slot == "当前" ? [] : ["--slot", slot]) + ["flash", name, image.path]
            command(temporary ? "临时启动镜像" : "刷入镜像", tool: "fastboot", args: args, destructive: true,
                    detail: "镜像：\(image.path)\n分区：\(temporary ? "临时启动，不写入分区" : name)\n槽位：\(slot)\n\n请确认镜像适配此设备。错误镜像可能导致设备无法启动。")
        } catch { self.error = error.localizedDescription }
    }

    func exportLog() {
        guard let url = saveURL(name: "VioletToolBox.log") else { return }
        do { try log.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}
