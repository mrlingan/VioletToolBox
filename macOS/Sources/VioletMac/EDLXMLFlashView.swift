import SwiftUI
import VioletCore

struct EDLXMLFlashView: View {
    @EnvironmentObject var model: AppModel
    let protect: Bool
    let protectData: Bool
    @ViewState<Set<Int>> private var selected = []
    @ViewState<Bool> private var includePatches = true
    @ViewState<Bool> private var gptOnly = false
    @ViewState<Bool> private var activate = true
    @ViewState<Bool> private var allowSecurity = false
    var body: some View {
        Card(title: "RawProgram / Patch 物理整包", icon: "doc.text") {
            HStack {
                Button("导入 XML…") { model.importEDLFlashPackage(includeDirectoryPatches: includePatches) }
                Toggle("包含同目录 patch*.xml", isOn: $includePatches).toggleStyle(.checkbox)
            }
            if let package = model.edlFlashPackage {
                Text(package.root.path).font(.caption).textSelection(.enabled)
                HStack {
                    Button("全选") { selected = Set(package.steps.map(\.id)) }
                    Button("仅选 GPT 与 Patch") { selected = Set(package.steps.filter { $0.isGPT || $0.kind == .patch }.map(\.id)) }
                    Button("清空") { selected = [] }
                }
                List(package.steps) { step in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(get: { selected.contains(step.id) }, set: { if $0 { selected.insert(step.id) } else { selected.remove(step.id) } })) {
                            Text("LUN\(step.lun) · \(step.kind.rawValue) · \(step.displayLabel)")
                        }.toggleStyle(.checkbox).frame(width: 295, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.kind == .patch ? "\(step.start):\(step.byteOffset) ← \(step.value)" : "LBA \(step.start) + \(step.sectors)\(step.sparse ? " · Sparse" : "")")
                            Text(step.source?.lastPathComponent ?? step.origin).foregroundStyle(.secondary)
                        }.font(.system(.caption, design: .monospaced))
                    }.padding(.vertical, 3)
                }.frame(height: 240)
                if !package.skipped.isEmpty { DisclosureGroup("跳过的 XML 占位 / 文件侧 Patch") { Text(package.skipped.joined(separator: "\n")).font(.caption).textSelection(.enabled) } }
                Toggle("仅执行 GPT 物理条目及其范围内的 Patch", isOn: $gptOnly).toggleStyle(.checkbox)
                Toggle("全部成功后按 A/B 镜像数量选择 UFS 启动 LUN", isOn: $activate).toggleStyle(.checkbox).disabled(gptOnly)
                Toggle("允许显式选中的 secdata 写入", isOn: $allowSecurity).toggleStyle(.checkbox)
                Text("这里使用 XML 的物理地址，支持 NUM_DISK_SECTORS 表达式、文件扇区偏移、分段与 Sparse。Sparse 的 DONT_CARE 会跳过，不展开为零覆盖其他分段。保护选项沿用上方分区保护；确认窗口会列出实际地址、跳过项和 Patch。修改 GPT 可能使设备无法启动，不能回滚已写入的分区。").font(.caption).foregroundStyle(.secondary)
                Button("解析设备范围并审阅…") { model.reviewEDLFlashPackage(selected: selected, gptOnly: gptOnly, protect: protect, protectData: protectData, activate: activate, allowSecurity: allowSecurity) }.disabled(model.edlContext == nil || selected.isEmpty)
            }
        }.onChange(of: model.edlFlashPackageRevision) { _ in selected = Set(model.edlFlashPackage?.steps.map(\.id) ?? []) }
    }
}
