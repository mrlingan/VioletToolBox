import SwiftUI
import VioletCore

// Explicit alias avoids the macOS 27 SDK macro sharing the State wrapper name.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Page: String, CaseIterable, Identifiable {
    case home = "设备概览", flash = "镜像刷写", flashPlan = "批量线刷", oujia = "欧加全量线刷", edl = "EDL / 9008", partitions = "可视分区 / GPT", boot = "Boot 组件", patch = "脱机修补", avb = "AVB 校验与签名", modules = "Root 模块", android = "安卓通用", payload = "Payload 提取", package = "OFP / OPS 解包", superImage = "Super / Sparse", rom = "ROM 资源", downgrade = "降级助手", downloads = "下载与续传", files = "文件与备份", apps = "应用管理", mirror = "屏幕与投屏", console = "命令控制台", settings = "工具与设置", about = "关于与移植进度"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "iphone.gen3"
        case .flash: return "bolt.shield"
        case .flashPlan: return "list.number"
        case .oujia: return "arrow.triangle.branch"
        case .edl: return "cable.connector.horizontal"
        case .partitions: return "rectangle.split.3x3"
        case .boot: return "shippingbox.and.arrow.backward"
        case .patch: return "bandage"
        case .avb: return "signature"
        case .modules: return "puzzlepiece.extension"
        case .android: return "wrench.and.screwdriver"
        case .payload: return "shippingbox"
        case .package: return "shippingbox.and.arrow.backward"
        case .superImage: return "square.3.layers.3d"
        case .rom: return "externaldrive.badge.icloud"
        case .downgrade: return "arrow.down.app"
        case .downloads: return "arrow.down.circle"
        case .files: return "folder"
        case .apps: return "square.grid.2x2"
        case .mirror: return "rectangle.on.rectangle"
        case .console: return "terminal"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .home: return "连接设备，让每一步操作清晰可见。"
        case .flash: return "通过 Fastboot 刷入分区或临时启动镜像。"
        case .flashPlan: return "导入线刷脚本，审阅顺序并执行设备绑定的计划。"
        case .oujia: return "按平台与槽位生成欧加全量镜像刷写计划。"
        case .edl: return "通过原生 USB 后端发送 Loader，读取 GPT 与物理分区。"
        case .partitions: return "读取分区表，回读镜像，批量写入或擦除并备份 GPT。"
        case .boot: return "分析 boot / init_boot，导出原始组件。"
        case .patch: return "使用 Mac 原生工具修补本地镜像并保存副本。"
        case .avb: return "核对签名与分区摘要，生成 RSA hash footer 副本。"
        case .modules: return "检查模块包，使用设备上的 Root 管理器安装与管理。"
        case .android: return "OCDT 项目配置与 Android 设备维护。"
        case .payload: return "从本地或在线 OTA / ZIP 中提取所需镜像与文件。"
        case .package: return "从欧加固件包中提取镜像与配置。"
        case .superImage: return "展开 Sparse，合并同版本 Super 分段。"
        case .rom: return "浏览机型与版本，获取 ROM 下载资源。"
        case .downgrade: return "查询 ColorOS 降级版本，校验并推送本地包。"
        case .downloads: return "保留下载进度，断开后继续。"
        case .files: return "在 Android 与 Mac 之间传输文件。"
        case .apps: return "安装、提取和管理设备上的应用。"
        case .mirror: return "截取屏幕、控制按键，或使用 scrcpy 投屏。"
        case .console: return "直接执行 ADB / Fastboot 命令，查看完整输出。"
        case .settings: return "检查本机工具，配置无线调试。"
        case .about: return "原生 macOS 客户端 · 基于开源 VioletToolBox"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Page?> private var page = .home
    @ViewState<Bool> private var showLog = true
    var active: Page { page ?? .home }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 25, weight: .medium)).foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("紫罗兰工具箱").font(.headline)
                        Text("VIOLET · macOS").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 14).padding(.top, 22)
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.icon).padding(.vertical, 6).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Label("macOS 原生版本", systemImage: "apple.logo").font(.caption)
                    Text("ADB · Fastboot · scrcpy").font(.caption2).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                deviceBar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(active.rawValue).font(.system(size: 28, weight: .bold))
                            Text(active.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Group {
                            switch active {
                            case .home: HomeView()
                            case .flash: FlashView()
                            case .flashPlan: FlashPlanView()
                            case .oujia: OujiaFlashView()
                            case .edl: EDLView()
                            case .partitions: PartitionView()
                            case .boot: BootImageView()
                            case .patch: RootPatchView()
                            case .avb: AVBImageView()
                            case .modules: RootModulesView()
                            case .android: AndroidToolsView()
                            case .payload: PayloadView()
                            case .package: FirmwarePackageView()
                            case .superImage: SuperImageView()
                            case .rom: ROMView()
                            case .downgrade: DowngradeView()
                            case .downloads: DownloadView()
                            case .files: FilesView()
                            case .apps: AppsView()
                            case .mirror: MirrorView()
                            case .console: ConsoleView()
                            case .settings: SettingsView()
                            case .about: AboutView()
                            }
                        }.disabled(model.busy)
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }.background(Color(nsColor: .windowBackgroundColor))
                if showLog { logPanel }
                Divider()
                HStack(spacing: 9) {
                    Circle().fill(model.busy ? .orange : model.selected?.ready == true ? .green : .secondary).frame(width: 7, height: 7)
                    Text(model.busy ? model.activity : model.selected?.statusLabel ?? "等待设备连接").font(.caption)
                    Spacer()
                    if model.busy {
                        if let progress = model.workProgress {
                            if progress.total > 0 {
                                ProgressView(value: progress.fraction).progressViewStyle(.linear).frame(width: 110)
                                Text("\(Int(progress.fraction * 100))%").font(.caption.monospacedDigit())
                            }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: progress.done), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView().controlSize(.small)
                        Button(model.cancellationAtBoundary ? "停止后续步骤" : "停止") { model.cancel() }.controlSize(.small)
                    }
                    Button(showLog ? "收起日志" : "显示日志") { showLog.toggle() }.buttonStyle(.borderless).font(.caption)
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        .onChange(of: model.selectedID) { _ in model.selectionChanged() }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: $model.pending) { operation in
            VStack(alignment: .leading, spacing: 20) {
                Label(operation.title, systemImage: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                ScrollView {
                    Text(operation.detail).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 420)
                HStack {
                    Spacer()
                    Button("取消") { model.pending = nil }.keyboardShortcut(.cancelAction)
                    Button("确认执行", role: .destructive) { model.pending = nil; operation.action() }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(model.busy)
                }
            }.padding(28).frame(width: 590)
        }
    }

    var deviceBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector").foregroundStyle(.purple)
            Picker("当前设备", selection: $model.selectedID) {
                Text(model.devices.isEmpty ? "未发现设备" : "请选择设备").tag("")
                if !model.selectedID.isEmpty, model.selected == nil { Text("设备已断开").tag(model.selectedID) }
                ForEach(model.devices) { device in Text("\(device.label) · \(device.statusLabel) · \(device.serial)").tag(device.id) }
            }.labelsHidden().frame(maxWidth: 530).disabled(model.busy || model.refreshing)
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh(force: true) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(model.busy || model.refreshing)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    var logPanel: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label("运行日志", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出") { model.exportLog() }.buttonStyle(.borderless)
                Button("清空") { model.log = "" }.buttonStyle(.borderless)
            }.font(.caption).padding(.horizontal, 18).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
                    Color.clear.frame(height: 1).id("end")
                }.frame(height: 125).onChange(of: model.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct Card<Content: View>: View {
    let title: String
    var icon: String = "square.stack"
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.headline)
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06), lineWidth: 1))
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        VStack(spacing: 20) {
            Card(title: model.selected?.label ?? "连接你的 Android 设备", icon: "iphone.gen3") {
                if let device = model.selected {
                    Text(device.statusLabel).foregroundStyle(device.ready ? .green : .orange)
                    Text("序列号  \(device.serial)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if !device.ready { Text("解锁手机，在弹窗中勾选「始终允许使用这台计算机进行调试」。").foregroundStyle(.secondary) }
                    if device.transport == .fastboot { Text("Fastboot 设备已就绪，可前往镜像刷写。读取设备信息的输出会显示在日志中。").foregroundStyle(.secondary) }
                } else {
                    Text("1. 在手机开发者选项中开启 USB 调试。\n2. 使用支持数据传输的 USB 线连接 Mac。\n3. 在手机上允许调试，然后选择上方设备。").foregroundStyle(.secondary).lineSpacing(7)
                    if model.locator.locate("adb") == nil { Label("尚未找到 ADB，请先在「工具与设置」配置。", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }
            }
            if !model.properties.isEmpty {
                LazyVGrid(columns: columns, spacing: 12) {
                    info("品牌 / 型号", [model.properties["ro.product.brand"], model.properties["ro.product.model"]].compactMap { $0 }.joined(separator: " "))
                    info("Android", model.properties["ro.build.version.release"] ?? "—")
                    info("设备代号", model.properties["ro.product.device"] ?? "—")
                    info("处理器 ABI", model.properties["ro.product.cpu.abi"] ?? "—")
                    info("安全补丁", model.properties["ro.build.version.security_patch"] ?? "—")
                    info("当前槽位", model.properties["ro.boot.slot_suffix"] ?? "—")
                }
            }
            Card(title: "快捷操作", icon: "bolt") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    Button("重启到系统") { reboot([]) }
                    Button("重启到 Bootloader") { reboot(["bootloader"]) }
                    Button("重启到 Recovery") { reboot(["recovery"]) }
                    Button("重启到 FastbootD") { reboot(["fastboot"]) }
                }.disabled(model.selected?.ready != true || model.selected?.state == "sideload")
                HStack {
                    Button("安装 APK…") { model.installAPKs() }.disabled(!model.adbReady)
                    Button("截取屏幕…") { model.screenshot() }.disabled(!model.adbReady)
                    Button("读取 Fastboot 信息") { model.command("读取 Fastboot 信息", tool: "fastboot", args: ["getvar", "all"]) }.disabled(!model.fastbootReady)
                }
            }
        }
    }
    func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    func reboot(_ destination: [String]) {
        model.command("重启设备", tool: model.fastbootReady ? "fastboot" : "adb", args: ["reboot"] + destination, destructive: true, detail: "设备将重启，请先保存正在进行的工作。")
    }
}
