import SwiftUI
import AppKit
import VioletCore

struct FlashView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var partition = "boot"
    @ViewState<String> private var slot = "当前"
    @ViewState<URL?> private var image = nil
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "刷入镜像", icon: "externaldrive.badge.bolt") {
                Text("需要设备处于 Fastboot / FastbootD 模式，并已解锁 Bootloader。刷写系统动态分区通常需要 FastbootD。").foregroundStyle(.secondary)
                HStack {
                    TextField("分区名，例如 boot", text: $partition)
                    Menu("常用分区") { ForEach(["boot", "init_boot", "vendor_boot", "recovery", "vbmeta", "dtbo", "super"], id: \.self) { value in Button(value) { partition = value } } }
                    Picker("槽位", selection: $slot) { ForEach(["当前", "a", "b"], id: \.self) { Text($0) } }.frame(width: 160)
                }
                HStack {
                    Image(systemName: "doc.zipper").foregroundStyle(.purple)
                    Text(image?.path ?? "选择适配设备的 .img 镜像").font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择镜像…") { image = model.chooseFiles(extensions: ["img", "bin"]).first }
                }.padding(14).background(.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("刷入所选分区") { model.flash(partition: partition, image: image, slot: slot, temporary: false) }.buttonStyle(.borderedProminent)
                    Button("临时启动镜像") { model.flash(partition: "boot", image: image, slot: slot, temporary: true) }
                }.disabled(!model.fastbootReady || image == nil)
                Text("确认窗口将列出目标序列号、镜像路径、分区和槽位。刷写时请勿拔线。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "槽位与 Bootloader", icon: "arrow.triangle.2.circlepath") {
                HStack {
                    Button("读取当前槽位") { model.command("读取槽位", tool: "fastboot", args: ["getvar", "current-slot"]) }
                    Button("切换到 A 槽") { setSlot("a") }
                    Button("切换到 B 槽") { setSlot("b") }
                }
                Button("解锁 Bootloader…", role: .destructive) {
                    model.command("解锁 Bootloader", tool: "fastboot", args: ["flashing", "unlock"], destructive: true, detail: "此操作通常会清空设备全部数据，并降低设备安全性。请先备份数据。设备端仍可能要求按键确认；部分品牌不支持此命令。")
                }
                Menu("更多 Bootloader 指令…") {
                    Button("OEM 解锁…") { model.command("OEM 解锁", tool: "fastboot", args: ["oem", "unlock"], destructive: true, detail: "可能清除全部用户数据；请先备份并在设备端确认。") }
                    Button("Flashing 回锁…") { lockBootloader(["flashing", "lock"]) }
                    Button("OEM 回锁…") { lockBootloader(["oem", "lock"]) }
                }
                Button("格式化设备（双清）…", role: .destructive) { model.resetFastbootData() }
            }.disabled(!model.fastbootReady)
            Card(title: "设备快捷工具", icon: "wrench.and.screwdriver") {
                HStack {
                    Button("读取一加 DDR 类型") { model.command("读取 DDR 类型", args: ["shell", "getprop", "ro.boot.ddr_type"]) }
                    Button("切换为文件传输") { model.command("切换 MTP", args: ["shell", "svc", "usb", "setFunctions", "mtp"], destructive: true, detail: "USB 功能将切换为 MTP，调试连接可能短暂中断。") }
                    Button("重启到 EDL…") { model.command("重启到 EDL", args: ["reboot", "edl"], destructive: true, detail: "设备将离开 Android，进入厂商支持的 EDL 模式。请确认已有退出方式；部分设备不支持。") }
                }.disabled(!model.adbReady)
                Button("启用 DIAG 基带调试端口（Root）…") {
                    model.command("启用 DIAG 端口", args: RootModuleCommands.shell("setprop sys.usb.config diag,adb"), destructive: true, detail: "需要手机允许 Shell Root 权限，将更改 USB 功能为 diag,adb。连接可能中断，仅适用于支持此属性的设备。")
                }.disabled(!model.adbReady)
                Button("擦除 FRP 分区…", role: .destructive) {
                    model.command("擦除 FRP 分区", tool: "fastboot", args: ["erase", "frp"], destructive: true, detail: "将擦除设备 frp 分区。仅在你有权维护且已备份的设备上使用；Bootloader 是否允许由设备决定。")
                }.disabled(!model.fastbootReady)
            }
            Card(title: "ADB Sideload", icon: "shippingbox") {
                Text("在 Recovery 中进入 Apply update from ADB，再选择设备支持的签名 OTA 包。").foregroundStyle(.secondary)
                Button("选择并传送 OTA ZIP…") {
                    if let zip = model.chooseFiles(extensions: ["zip"]).first {
                        model.command("安装 OTA", args: ["sideload", zip.path], destructive: true, detail: "将安装所选 OTA 更新，确认包适用于当前设备及版本。")
                    }
                }.disabled(model.selected?.state != "sideload")
            }
        }.textFieldStyle(.roundedBorder)
    }
    func setSlot(_ value: String) {
        model.command("切换槽位", tool: "fastboot", args: ["set_active", value], destructive: true, detail: "切换到槽位 \(value)。请确保该槽位存在完整且可启动的系统。")
    }
    func lockBootloader(_ args: [String]) {
        model.command("回锁 Bootloader", tool: "fastboot", args: args, destructive: true, detail: "请先恢复完整且受厂商信任的原厂固件。错误回锁可能导致设备无法启动，并可能清空用户数据。")
    }
}

struct FilesView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var remote = "/sdcard/Download/"
    var body: some View {
        VStack(spacing: 20) {
            FileBrowserCard()
            Card(title: "文件传输", icon: "arrow.left.arrow.right") {
                TextField("设备路径", text: $remote).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Mac → 设备…") { model.transfer(push: true, remote: remote) }.buttonStyle(.borderedProminent)
                    Button("设备 → Mac…") { model.transfer(push: false, remote: remote) }
                    Button("列出目录") {
                        model.command("列出目录", args: ["shell", "ls -la -- " + Input.remoteQuote(remote)])
                    }
                }
                Text("发送支持多选文件。接收时选择 Mac 上的目标文件夹；目录会递归复制。目录列表显示在日志中。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "照片与视频备份", icon: "photo.stack") {
                Text("通过 ADB 复制相机、截图及相册目录，保留设备上的原文件。").foregroundStyle(.secondary)
                HStack {
                    Button("备份相机 DCIM…") { model.transfer(push: false, remote: "/sdcard/DCIM") }
                    Button("备份图片 Pictures…") { model.transfer(push: false, remote: "/sdcard/Pictures") }
                    Button("备份视频 Movies…") { model.transfer(push: false, remote: "/sdcard/Movies") }
                }
                Text("备份仅覆盖所选共享存储目录，不包含应用私有数据和通讯录。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "存储信息", icon: "internaldrive") {
                Button("读取存储占用") { model.command("读取存储", args: ["shell", "df", "-h", "/sdcard", "/data"]) }
            }
        }.disabled(!model.adbReady)
    }
}

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var thirdParty = true
    @ViewState<Bool> private var disabledOnly = false
    @ViewState<String> private var search = ""
    @ViewState<Set<String>> private var selected = []
    var selectedPackages: [String] { model.packages.filter { selected.contains($0) } }
    var filtered: [String] { model.packages.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        Card(title: "设备应用", icon: "square.grid.2x2") {
            HStack {
                Toggle("仅第三方应用", isOn: $thirdParty).toggleStyle(.checkbox)
                Toggle("仅冻结应用", isOn: $disabledOnly).toggleStyle(.checkbox)
                Spacer()
                Button("读取列表") { selected = []; model.loadPackages(thirdParty: thirdParty, disabledOnly: disabledOnly) }
                Button("安装 APK…") { model.installAPKs() }.buttonStyle(.borderedProminent)
            }
            TextField("搜索应用包名", text: $search).textFieldStyle(.roundedBorder)
            if model.packages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("连接设备后，点击「读取列表」。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 150)
            } else {
                List(filtered, id: \.self, selection: $selected) { package in
                    Label(package, systemImage: "app").font(.system(.body, design: .monospaced)).padding(.vertical, 4).tag(package)
                }.frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("\(filtered.count) / \(model.packages.count) 个应用").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("提取 APK…") { model.extractAPKs(selectedPackages) }
                Button("复制包名") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedPackages.joined(separator: "\n"), forType: .string) }
                Button("冻结…") { appCommand(["shell", "pm", "disable-user", "--user", "0"], title: "冻结应用", warning: "冻结后应用将停止运行。冻结关键系统应用可能导致系统异常。") }
                Button("解冻") { appCommand(["shell", "pm", "enable"], title: "解冻应用") }
                Button("清除数据…", role: .destructive) { appCommand(["shell", "pm", "clear"], title: "清除应用数据", warning: "该应用的本地数据与登录状态将被删除。") }
                Button("卸载…", role: .destructive) { appCommand(["uninstall"], title: "卸载应用", warning: "应用及其本地数据将被删除。") }
            }.disabled(selectedPackages.isEmpty)
            HStack {
                Text("选中 \(selectedPackages.count) 项；按住 ⌘ 或 ⇧ 多选。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("冻结小米更新器…") { model.batchAppCommand(["com.android.updater"], prefix: ["shell", "pm", "disable-user", "--user", "0"], title: "冻结小米更新器", warning: "将停用小米系统更新器，仅适用于相关 MIUI / HyperOS 设备。") }
                Button("恢复更新器") { model.batchAppCommand(["com.android.updater"], prefix: ["shell", "pm", "enable"], title: "恢复小米更新器") }
            }
            Text("提取会同时保存 base APK 与 split APK。批量任务按序执行，失败即停止；已完成步骤不自动回滚。安装功能用于独立 APK 文件。").font(.caption).foregroundStyle(.secondary)
        }.disabled(!model.adbReady)
            .onChange(of: model.selectedID) { _ in selected = [] }
    }
    func appCommand(_ prefix: [String], title: String, warning: String = "") {
        model.batchAppCommand(selectedPackages, prefix: prefix, title: title, warning: warning)
    }
}

struct ConsoleView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var tool = "adb"
    @ViewState<String> private var line = "shell getprop ro.product.model"
    var body: some View {
        Card(title: "命令控制台", icon: "terminal") {
            Text("自动绑定上方选中的设备。填写工具名之后的参数，输出见下方日志。").foregroundStyle(.secondary)
            HStack {
                Picker("工具", selection: $tool) { Text("adb").tag("adb"); Text("fastboot").tag("fastboot") }.labelsHidden().frame(width: 110)
                TextField("命令参数", text: $line).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                Button("执行…") { execute() }.buttonStyle(.borderedProminent)
                    .disabled(model.selected?.transport.rawValue != tool || model.selected?.ready != true)
            }
            Text("支持引号与含空格路径。ADB shell 后的内容由 Android 设备解释。自定义命令执行前会显示完整确认信息。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("设备属性") { tool = "adb"; line = "shell getprop" }
                Button("电池状态") { tool = "adb"; line = "shell dumpsys battery" }
                Button("抓取日志") { tool = "adb"; line = "logcat -d -t 500" }
                Button("Fastboot 参数") { tool = "fastboot"; line = "getvar all" }
            }
        }
    }
    func execute() {
        do {
            let args = try Input.deviceArguments(line, tool: tool)
            model.command("执行自定义命令", tool: tool, args: args, destructive: true, detail: "请确认命令及其影响。此操作将在所选 Android 设备上执行。")
        } catch { model.error = error.localizedDescription }
    }
}
