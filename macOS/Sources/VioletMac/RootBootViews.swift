import SwiftUI
import VioletCore

struct BootImageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "Boot / init_boot 组件", icon: "shippingbox.and.arrow.backward") {
                Text("支持 Android boot header v0–v4，检查组件范围后导出 kernel、ramdisk、second、recovery DTBO、DTB 或 boot_signature。").foregroundStyle(.secondary)
                Button("打开 Boot / init_boot…") { model.openBootImage() }.buttonStyle(.borderedProminent)
                if let image = model.bootImage {
                    Text(image.sourceURL.lastPathComponent).font(.system(.body, design: .monospaced))
                    Text("\(image.kind) · header v\(image.version) · page \(image.pageSize) bytes").font(.caption).foregroundStyle(.secondary)
                    ForEach(image.components) { part in
                        HStack { Text(part.name); Spacer(); Text("offset \(part.offset) · \(part.size) bytes").foregroundStyle(.secondary) }.font(.system(.caption, design: .monospaced))
                    }
                    if !image.commandLine.isEmpty { Text(image.commandLine).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    Button("导出组件与偏移清单…") { model.exportBootImage() }.buttonStyle(.borderedProminent)
                }
                Text("导出保留组件原始字节；ramdisk 仍保留压缩格式。尚不包含 cpio 修改、Root 注入、重打包及 vendor_boot。导出的 boot_signature 未单独验证。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AVBImageView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<URL?> private var source = nil
    @ViewState<URL?> private var key = nil
    @ViewState<String> private var partition = "boot"
    @ViewState<String> private var size = ""
    @ViewState<String> private var rollback = "0"
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "AVB 分析与验证", icon: "checkmark.shield") {
                Button("打开 vbmeta / 带 AVB footer 的镜像…") { model.openAVBImage() }
                if let image = model.avbImage {
                    Text(image.sourceURL.lastPathComponent).font(.system(.body, design: .monospaced))
                    Text("algorithm \(image.algorithm) · rollback \(image.rollbackIndex) · flags \(image.flags) · tags \(image.descriptorTags.map(String.init).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    Text("内嵌公钥 SHA-256：\(image.publicKeySHA256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    ForEach(image.hashes) { hash in Text("\(hash.partition) · \(hash.algorithm) · \(hash.imageSize) bytes").font(.caption) }
                    HStack {
                        Button("选择关联分区镜像…") { model.chooseAVBBindings() }
                        Button("校验签名与可用分区") { model.verifyAVBImage() }.buttonStyle(.borderedProminent)
                    }
                    Text("关联镜像以文件名对应分区，如 boot.img。仅含一个 hash 描述符的 footer 镜像自动校验自身数据。").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.avbBindings.keys.sorted(), id: \.self) { name in Text("\(name) → \(model.avbBindings[name]!.lastPathComponent)").font(.caption) }
                    if !model.avbResult.isEmpty { Text(model.avbResult).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                Text("支持 SHA256 / SHA512 + RSA 2048 / 4096 / 8192。签名通过表示与内嵌公钥一致；厂商信任链、Hashtree 及链式 vbmeta 尚未验证。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "生成 AVB 签名副本", icon: "signature") {
                Button("选择要签名的原始分区镜像…") {
                    if let url = model.chooseFiles(extensions: ["img", "bin"]).first {
                        source = url; partition = url.deletingPathExtension().lastPathComponent
                        if let image = try? AVBImage.open(url), image.originalSize != nil { size = String(image.partitionSize); rollback = String(image.rollbackIndex) }
                        else { size = ""; rollback = "0" }
                    }
                }
                if let source { Text(source.lastPathComponent).font(.caption) }
                Button("选择 RSA 私钥 PEM…") { key = model.chooseFiles(extensions: ["pem", "key"]).first }
                if let key { Text(key.lastPathComponent).font(.caption) }
                TextField("分区名，如 boot / init_boot", text: $partition).textFieldStyle(.roundedBorder)
                TextField("真实分区容量，十进制 bytes，4096 对齐", text: $size).textFieldStyle(.roundedBorder)
                TextField("Rollback index", text: $rollback).textFieldStyle(.roundedBorder)
                Button("签名并另存为…") {
                    if let source, let key { model.signAVBCopy(source: source, key: key, partition: partition, size: size, rollback: rollback) }
                }.buttonStyle(.borderedProminent).disabled(source == nil || key == nil || size.isEmpty)
                Text("用自己的未加密 RSA PKCS#1 / PKCS#8 私钥生成 SHA256_RSA hash footer。私钥只在内存中使用；输出自校验后保存，不覆盖原文件。自定义签名是否被设备接受取决于 Bootloader 信任配置。请填写真实分区容量及合适的 rollback index。").font(.caption).foregroundStyle(.secondary)
                Text("尚不包含厂商私钥、Hashtree 重签名或独立 vbmeta 信任链重建。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RootModulesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "模块 ZIP 检查与安装", icon: "puzzlepiece.extension") {
                Button("选择模块 ZIP…") { model.chooseModulePackages() }
                ForEach(model.modulePackages) { package in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(package.properties.name) · \(package.properties.version)").font(.callout)
                        Text("\(package.id) · \(package.sourceURL.lastPathComponent)\nSHA-256：\(package.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
                Button("请求 Root 授权并检测管理器") { model.detectRootManagers() }.disabled(!model.adbReady)
                if model.rootDeviceID == model.selectedID, !model.rootManagers.isEmpty {
                    Picker("Root 管理器", selection: $model.rootManagerID) {
                        Text("请选择管理器").tag("")
                        ForEach(model.rootManagers) { manager in Text(manager.id + " · " + manager.version).tag(manager.id) }
                    }
                }
                Button("审阅并安装所选模块…") { model.installRootModules() }.buttonStyle(.borderedProminent).disabled(!model.rootReady || model.modulePackages.isEmpty)
                Text("支持已有 Magisk、KernelSU、APatch 的设备。元数据检查不代表模块可信；安装会在手机上运行 Root 脚本。逐个安装，失败即停止，重启由你决定。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "已安装模块", icon: "list.bullet.rectangle") {
                Button("读取 / 刷新模块列表") { model.refreshRootModules() }.disabled(!model.rootReady)
                ForEach(model.installedModules) { module in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(module.properties.name) · \(module.id)").font(.callout)
                        Text("\(module.properties.version) · \(module.disabled ? "已停用" : "已启用")\(module.removing ? " · 待卸载" : "")\(module.updating ? " · 待更新" : "")").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(module.disabled ? "启用…" : "停用…") { model.changeRootModule(module, action: module.disabled ? .enable : .disable) }
                            Button(module.removing ? "取消卸载…" : "标记卸载…") { model.changeRootModule(module, action: module.removing ? .undoRemove : .remove) }
                        }.disabled(!model.rootReady)
                    }.padding(.vertical, 4)
                }
                Text("模块状态以 /data/adb/modules 标记文件为准，修改后重启生效。更换设备需重新检测 Root；本页不会自动重启或删除整个模块目录。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
