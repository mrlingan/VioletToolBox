import SwiftUI
import AppKit
import VioletCore

struct AndroidToolsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var project = ""
    @ViewState<OCDTImage.Platform> private var platform = .mtk
    @ViewState<OCDTImage.Variant> private var variant = .standard
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "OCDT 分析", icon: "doc.text.magnifyingglass") {
                Button("打开 OCDT 镜像…") { model.openOCDT() }
                if let image = model.ocdtImage {
                    Text(image.sourceURL.lastPathComponent).font(.system(.body, design: .monospaced))
                    Text("\(image.size) bytes · project IDs：\(image.projectIDs.map(String.init).joined(separator: ", ")) · \(image.variant.rawValue)").font(.caption).textSelection(.enabled)
                    Text(image.osigVersion.map { "OSIG version \($0) · \(image.osigHasSignature ? "签名区域含数据（未验证）" : "签名区域为空")" } ?? "不含 OSIG 区块").font(.caption).foregroundStyle(.secondary)
                    if image.projectIDs.contains(0) { Text("配置包含空项目号，请核对机型。生成的 OCDT 不能替代原厂签名或原始备份。").font(.caption).foregroundStyle(.orange) }
                }
            }
            Card(title: "生成 OCDT", icon: "doc.badge.gearshape") {
                TextField("项目号，十进制 1–65535", text: $project).textFieldStyle(.roundedBorder)
                Picker("平台", selection: $platform) { ForEach(OCDTImage.Platform.allCases, id: \.self) { Text($0.rawValue) } }
                Picker("变体", selection: $variant) { ForEach(OCDTImage.Variant.allCases, id: \.self) { Text($0.rawValue) } }
                Button("生成并保存 ocdt.img…") { model.generateOCDT(project: project, platform: platform, variant: variant) }.buttonStyle(.borderedProminent)
                Text("沿用上游 geyixue 配置算法，支持 standard / fill02 / geyixue_fill；mixed_projid 仅支持上游数据库的 22801 / 21644。项目号应从适配固件的 version_info.txt 确认。").font(.caption).foregroundStyle(.secondary)
                Text("生成文件不带有效厂商 RSA 签名，不能保证可用于设备启动。本工具只保存本地副本，不自动刷入；请保留原始 OCDT 备份。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "设备维护", icon: "wrench.and.screwdriver") {
                Button("修复 ADB 临时目录权限（Root）…") {
                    model.command("修复 ADB 临时目录权限", args: RootModuleCommands.shell("mkdir -p /data/local/tmp && chmod 0777 /data/local/tmp && chcon u:object_r:shell_data_file:s0 /data/local/tmp"), destructive: true, detail: "需要手机授权 Root。将修复 /data/local/tmp 的目录权限与 SELinux 标签，不删除目录中的文件。")
                }.disabled(!model.adbReady)
            }
        }
    }
}

extension AppModel {
    func openOCDT() {
        guard let url = chooseFiles(extensions: ["img", "bin"]).first else { return }
        perform("分析 OCDT") {
            self.ocdtImage = nil
            let image = try await Task.detached { try OCDTImage.open(url) }.value
            try self.workControl.check(); self.ocdtImage = image
            self.append("OCDT projects：" + image.projectIDs.map(String.init).joined(separator: ", "))
        }
    }
    func generateOCDT(project: String, platform: OCDTImage.Platform, variant: OCDTImage.Variant) {
        guard let number = UInt16(project), number > 0 else { error = "项目号应为十进制 1–65535。"; return }
        guard let target = saveURL(name: "ocdt.img") else { return }
        perform("生成 OCDT") {
            let control = self.workControl
            let file = try await Task.detached { try OCDTImage.generate(project: number, platform: platform, variant: variant, to: target, control: control) }.value
            self.append("已生成本地 OCDT 副本：\(file.path)")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}
