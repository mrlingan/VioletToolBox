import SwiftUI
import AppKit
import VioletCore

enum RootPatchScheme: String, CaseIterable {
    case magisk = "Magisk / Alpha", apatch = "APatch", folk = "FolkPatch", ksu = "KernelSU LKM", suki = "SukiSU LKM", resuki = "ReSukiSU LKM"
    var isLKM: Bool { [.ksu,.suki,.resuki].contains(self) }
    var moduleFolder: String { self == .suki ? "SukiSU_Ultra" : self == .resuki ? "ReSukiSU" : "KernelSU" }
}

struct RootPatchView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<RootPatchScheme> private var scheme = .magisk
    @ViewState<URL?> private var source = nil
    @ViewState<URL?> private var apk = nil
    @ViewState<URL?> private var payload = nil
    @ViewState<URL?> private var initBinary = nil
    @ViewState<String> private var architecture = "arm64-v8a"
    @ViewState<String> private var kmi = "android14-6.1"
    @ViewState<Bool> private var keepVerity = true
    @ViewState<Bool> private var keepEncryption = true
    @ViewState<Bool> private var patchVBMeta = false
    var root: URL? { Bundle.main.resourceURL?.appendingPathComponent("RootPayloads") }
    var defaultPayload: URL? {
        let url = scheme.isLKM ? root?.appendingPathComponent("LKM_Patch/\(scheme.moduleFolder)/\(kmi)_kernelsu.ko") : root?.appendingPathComponent("KernelPatch/" + (scheme == .folk ? "fkpimg" : "akpimg"))
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    var defaultInit: URL? { (root?.appendingPathComponent("ksuinit-aarch64")).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "原生脱机修补", icon: "bandage") {
                Picker("方案", selection: $scheme) { ForEach(RootPatchScheme.allCases, id: \.self) { Text($0.rawValue) } }
                Button("选择原厂 boot / init_boot…") { source = model.chooseFiles(extensions: ["img", "bin"]).first }
                if let source { Text(source.path).font(.caption).textSelection(.enabled) }
                if scheme == .magisk {
                    Button("选择 Magisk / Alpha 管理器 APK…") { apk = model.chooseFiles(extensions: ["apk"]).first }
                    if let apk { Text(apk.lastPathComponent).font(.caption) }
                    Picker("Android 目标架构", selection: $architecture) { ForEach(["arm64-v8a","armeabi-v7a","x86_64","x86","riscv64"], id: \.self) { Text($0) } }
                    HStack { Toggle("保留 verity", isOn: $keepVerity); Toggle("保留强制加密", isOn: $keepEncryption) }.toggleStyle(.checkbox)
                    Toggle("修改 vbmeta 标志", isOn: $patchVBMeta).toggleStyle(.checkbox)
                } else {
                    if scheme.isLKM {
                        Picker("KMI", selection: $kmi) { ForEach(["android12-5.10","android13-5.10","android13-5.15","android14-5.15","android14-6.1","android15-6.6","android16-6.12","android17-6.18"], id: \.self) { Text($0) } }
                    }
                    Button(scheme.isLKM ? "选择自定义 kernelsu.ko…" : "选择自定义 kpimg…") { payload = model.chooseFiles().first }
                    Text((payload ?? defaultPayload)?.path ?? "未找到对应内核资源，请选择文件。").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if payload != nil { Button("使用内置资源") { payload = nil } }
                    if scheme.isLKM {
                        Button("选择自定义 ksuinit…") { initBinary = model.chooseFiles().first }
                        Text((initBinary ?? defaultInit)?.lastPathComponent ?? "未提供 ksuinit，将使用 ksud 内嵌资源。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("修补并另存为…") { patch() }.buttonStyle(.borderedProminent)
                    .disabled(source == nil || (scheme == .magisk ? apk == nil : payload == nil && defaultPayload == nil))
                Text("在独立临时目录处理文件，原始镜像保持不变；检查输出 header 后另存为新文件。此页只处理 Mac 本地镜像，不会自动刷机。请使用适配系统版本、处理器、KMI 的原厂镜像和资源。").font(.caption).foregroundStyle(.secondary)
                Text("Magisk / Alpha 从所选 APK 提取 ramdisk 组件；APatch / FolkPatch 需要含 kernel 的 boot。已修改镜像可能需要相应 AVB 信任配置。LKM 各分支的实际启动兼容性仍需设备验证。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Mac 本机工具", icon: "wrench.and.screwdriver") {
                ForEach(["magiskboot","kptools","ksud"], id: \.self) { name in
                    HStack(alignment: .top) {
                        Image(systemName: model.locator.locate(name) == nil ? "minus.circle" : "checkmark.circle.fill")
                        Text(name).font(.system(.caption, design: .monospaced)).frame(width: 85, alignment: .leading)
                        Text(model.locator.locate(name)?.path ?? "未找到，请在工具与设置指定原生工具目录。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.onChange(of: scheme) { _ in payload = nil }
    }
    func patch() {
        guard let source else { return }
        let recipe: RootPatchRecipe
        if scheme == .magisk {
            guard let apk else { return }
            recipe = .magisk(apk: apk, architecture: architecture, keepVerity: keepVerity, keepEncryption: keepEncryption, patchVBMeta: patchVBMeta)
        } else {
            guard let payload = payload ?? defaultPayload else { return }
            recipe = scheme.isLKM ? .lkm(module: payload, kmi: kmi, initBinary: initBinary ?? defaultInit) : .kernelPatch(kpimg: payload, folkPatch: scheme == .folk)
        }
        for name in recipe.requiredTools where model.locator.locate(name) == nil { model.error = "找不到 Mac 原生 \(name)，请在工具与设置配置。"; return }
        guard let destination = model.saveURL(name: source.deletingPathExtension().lastPathComponent + "_patched.img") else { return }
        model.perform("脱机修补 · " + scheme.rawValue) {
            let control = model.workControl
            let result = try await NativeRootPatcher.patch(source: source, destination: destination, recipe: recipe, control: control, execute: { name, args, directory, env in
                try await model.executeHost(name, args: args, directory: directory, environment: env)
            })
            model.append("已保存修补镜像：\(result.path)")
            NSWorkspace.shared.activateFileViewerSelecting([result])
        }
    }
}
