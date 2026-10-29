import SwiftUI
import AppKit
import VioletCore

struct MirrorView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var size = "1920"
    @ViewState<String> private var fps = "60"
    @ViewState<Bool> private var noAudio = false
    @ViewState<Bool> private var stayAwake = true
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "scrcpy 投屏", icon: "display") {
                Text("在独立窗口显示并控制设备屏幕。投屏期间可继续使用其他 ADB 功能。").foregroundStyle(.secondary)
                HStack {
                    Picker("最长边", selection: $size) { ForEach(["1280", "1920", "2560"], id: \.self) { Text($0 + " px") } }
                    Picker("帧率", selection: $fps) { ForEach(["30", "60", "90", "120"], id: \.self) { Text($0 + " fps") } }
                }
                HStack {
                    Toggle("禁用音频", isOn: $noAudio)
                    Toggle("保持唤醒", isOn: $stayAwake)
                }.toggleStyle(.checkbox)
                HStack {
                    Button("开始投屏") { model.startMirror(size: size, fps: fps, noAudio: noAudio, stayAwake: stayAwake) }
                        .buttonStyle(.borderedProminent).disabled(!model.adbReady || model.mirroring)
                    Button("停止投屏") { model.stopMirror() }.disabled(!model.mirroring)
                    if model.mirroring { Label("投屏运行中", systemImage: "record.circle").foregroundStyle(.green) }
                }
                if model.locator.locate("scrcpy") == nil {
                    Text("未找到 scrcpy。可在终端安装：brew install scrcpy").font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.orange)
                }
            }
            Card(title: "屏幕与按键", icon: "hand.tap") {
                HStack {
                    Button("强制竖屏") { model.screenRotation(0) }
                    Button("强制横屏") { model.screenRotation(1) }
                    Button("自动旋转") { model.screenRotation(nil) }
                }
                HStack {
                    Button("截图到 Mac…") { model.screenshot() }.buttonStyle(.borderedProminent)
                    Button("返回") { key("4") }
                    Button("主页") { key("3") }
                    Button("最近任务") { key("187") }
                    Button("电源") { key("26") }
                }
                HStack {
                    Button("音量 +") { key("24") }
                    Button("音量 −") { key("25") }
                    Button("静音") { key("164") }
                    Button("展开通知栏") { model.command("展开通知栏", args: ["shell", "cmd", "statusbar", "expand-notifications"]) }
                }
            }.disabled(!model.adbReady)
        }
    }
    func key(_ value: String) { model.command("设备按键", args: ["shell", "input", "keyevent", value]) }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var endpoint = ""
    @ViewState<String> private var pairingEndpoint = ""
    @ViewState<String> private var code = ""
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "工具环境", icon: "wrench.and.screwdriver") {
                ForEach(["adb", "fastboot", "scrcpy"], id: \.self) { tool in
                    HStack(alignment: .top) {
                        Image(systemName: model.locator.locate(tool) == nil ? "minus.circle" : "checkmark.circle.fill")
                            .foregroundStyle(model.locator.locate(tool) == nil ? .orange : .green)
                        Text(tool).font(.system(.body, design: .monospaced)).frame(width: 70, alignment: .leading)
                        Text(model.locator.locate(tool)?.path ?? "未安装").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                HStack {
                    TextField("自定义工具目录（可选）", text: $model.customDirectory).textFieldStyle(.roundedBorder)
                    Button("选择…") {
                        if let folder = model.chooseFiles(directories: true).first { model.customDirectory = folder.path }
                    }
                }
                Text("优先使用自定义目录，再查找应用内工具、Homebrew 和 Android SDK。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("检测工具版本") {
                        model.perform("检测工具版本") {
                            for tool in ["adb", "fastboot", "scrcpy"] where model.locator.locate(tool) != nil {
                                _ = try await model.execute(tool, [tool == "adb" ? "version" : "--version"], global: true, timeout: 10)
                            }
                        }
                    }
                    Button("启动 ADB 服务") { server("start-server") }
                    Button("重启 ADB 服务…") {
                        model.pending = PendingOperation(title: "重启 ADB 服务", detail: "将暂时断开这台 Mac 上所有 ADB 会话，包括其他程序的调试及投屏。") {
                            model.perform("重启 ADB 服务") {
                                _ = try await model.execute("adb", ["kill-server"], global: true)
                                _ = try await model.execute("adb", ["start-server"], global: true)
                            }
                        }
                    }
                }
                Text("手动安装：brew install --cask android-platform-tools\n投屏组件：brew install scrcpy").font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                Link("Google 官方 Platform Tools 下载", destination: URL(string: "https://developer.android.com/tools/releases/platform-tools")!)
            }
            Card(title: "无线调试 · Android 11+", icon: "wifi") {
                Text("手机与 Mac 需在同一网络。打开开发者选项 → 无线调试 → 使用配对码配对设备。配对端口与连接端口通常不同。").foregroundStyle(.secondary)
                HStack {
                    TextField("配对地址，例如 192.168.1.20:37123", text: $pairingEndpoint)
                    SecureField("6 位配对码", text: $code).frame(width: 130)
                    Button("配对") { pair() }.disabled(code.isEmpty || pairingEndpoint.isEmpty)
                }
                HStack {
                    TextField("连接地址，例如 192.168.1.20:41235", text: $endpoint)
                    Button("连接") { connect() }.disabled(endpoint.isEmpty)
                }
                Text("配对码不会写入运行日志。连接成功后点击顶部刷新并选择无线设备。").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
        }.onChange(of: model.customDirectory) { value in UserDefaults.standard.set(value, forKey: "toolsDirectory") }
    }
    func server(_ action: String) {
        model.perform("ADB 服务") { _ = try await model.execute("adb", [action], global: true) }
    }
    func pair() {
        do {
            let address = try Input.endpoint(pairingEndpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { throw InputError.invalid("配对码应为 6 位数字。") }
            let input = Data((code + "\n").utf8)
            code = ""
            model.perform("无线配对") {
                let result = try await model.execute("adb", ["pair", address], global: true, timeout: 30, input: input)
                guard result.stdout.localizedCaseInsensitiveContains("Successfully paired") else { throw InputError.invalid(result.text) }
            }
        } catch { model.error = error.localizedDescription }
    }
    func connect() {
        do {
            let address = try Input.endpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            model.perform("无线连接") {
                let result = try await model.execute("adb", ["connect", address], global: true, timeout: 30)
                guard result.stdout.contains("connected to") else { throw InputError.invalid(result.text) }
            }
        } catch { model.error = error.localizedDescription }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "紫罗兰工具箱 · macOS 0.4.0 开发中", icon: "sparkles") {
                Text("为 Mac 重新实现的 SwiftUI 客户端，面向 macOS 13 及以上系统。沿用 VioletToolBox 的功能思路与 GPL-3.0-or-later 许可。").foregroundStyle(.secondary)
                Link("上游项目 · Smart-Paocai / VioletToolBox", destination: URL(string: "https://github.com/Smart-Paocai/VioletToolBox")!)
                Text("这是独立移植版本，尚未覆盖 Windows 版全部功能。").font(.callout).foregroundStyle(.orange)
            }
            Card(title: "功能移植状态", icon: "checklist") {
                status("已实现", "多设备识别、设备属性、模式重启、无线配对与连接、ADB 服务管理", .green)
                status("已实现", "Fastboot 分区刷写、槽位切换、临时启动、Bootloader 解锁、OTA Sideload", .green)
                status("已实现", "文件收发、相册备份、批量 APK 安装、split APK 提取、冻结与解冻、卸载及清数据", .green)
                status("已实现", "截图、虚拟按键、scrcpy 投屏、ADB / Fastboot 控制台、日志导出", .green)
                status("已有功能", "本地 OTA ZIP / Payload、BZip2 / XZ、SHA-256、ROM API 与单连接续传；本轮共享 Payload 解析 / 输出重构待回归", .secondary)
                status("已实现", "传统高通 / MTK OFP、OPS MBox 4/5/6 解包、Sparse 展开、分段 Super 合并与分组映射", .green)
                status("已实现", "Boot v0–v4 组件、AVB RSA 校验及 hash footer 签名副本、Root 模块管理、OCDT 分析与生成", .green)
                status("已实现", "ADB / Fastboot 可视分区、流式回读、批量写入与擦除、基带备份、GPT CRC 校验与备份、rawprogram XML", .green)
                status("本地验证", "Mac 原生 Magisk / Alpha ramdisk 修补、KSU / SukiSU / ReSukiSU LKM 注入；APatch / FolkPatch 流程接通，真实启动待验", .secondary)
                status("待验收", "声明式批量线刷、RawProgram 镜像导入、跨模式等待、逻辑分区操作、小米常见防回滚模板、欧加四模式计划及 ARB 镜像索引", .orange)
                status("待验收", "通用 EDL 后端、Loader、GPT / 分区操作、主备表恢复、A/B / 启动 LUN、RawProgram / Patch；工具及定向补丁尚未构建", .orange)
                status("待验收", "联想 SN / MTM / Y700 查包、ColorOS 降级助手握手 / 查询 / APK / MD5 / 推送 / 安装请求；仅源码接入", .orange)
                status("待验收", "远程 Range / ZIP64 / Stored Payload、通用 ZIP / Deflate / CRC、metadata、ZSTD 解码源码与 ROM / 降级详情入口", .orange)
                status("待移植", "EDL 厂商认证 / VIP、OEM / 版本 / 动态 Super、欧加全自动救砖、lpmake、加密 ZIP OFP", .orange)
                status("待移植", "一加全自动 Root、AVB 链重建、降级助手随包 APK、远程块缓存 / 完整厂商链接、多线程下载及其余 Windows 对齐项", .orange)
                status("当前安排", "按用户要求先继续功能移植，暂不进行新增编译、测试与界面验收。", .secondary)
            }
        }
    }
    func status(_ title: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color).frame(width: 60, alignment: .leading)
            Text(detail).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
