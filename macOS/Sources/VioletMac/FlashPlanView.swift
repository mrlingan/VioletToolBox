import SwiftUI
import VioletCore

struct FlashPlanView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var excludeSensitive = true
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "批量线刷计划", icon: "list.number") {
                HStack {
                    Button("导入 BAT / SH / JSON…") { model.importFlashPlan() }.buttonStyle(.borderedProminent)
                    Button("从镜像目录生成…") { model.scanFlashDirectory(excludeSensitive: excludeSensitive) }
                    Button("RawProgram XML…") { model.importRawProgramImages() }
                }
                Toggle("生成时排除 persist / OCDT / 基带敏感镜像", isOn: $excludeSensitive).toggleStyle(.checkbox)
                Text("导入只解析声明式 Fastboot 操作，不运行原脚本。支持跨模式步骤、逻辑分区增删 / 调整，以及已识别的小米机型和防回滚模板；未识别的控制流会阻止执行。").font(.caption).foregroundStyle(.secondary)
                if let plan = model.flashPlan {
                    Text(plan.root.path).font(.caption).textSelection(.enabled)
                    if let imported = model.rawProgramImages, !imported.skipped.isEmpty {
                        DisclosureGroup("RawProgram 跳过 \(imported.skipped.count) 项") {
                            Text(imported.skipped.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Text("机型：\(plan.document.product ?? "未声明")")
                        Text("防回滚上限：\(plan.document.maximumAnti.map(String.init) ?? "未声明")")
                    }.font(.caption).foregroundStyle(.secondary)
                    List(Array(plan.document.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top) {
                            Text("\(index+1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 35)
                            Text(step.summary).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button { model.moveFlashStep(index, direction: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).help("上移一步").disabled(!plan.canExecute || index == 0)
                            Button { model.moveFlashStep(index, direction: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).help("下移一步").disabled(!plan.canExecute || index == plan.document.steps.count - 1)
                            Button { model.removeFlashStep(index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("从计划移除此步骤").disabled(!plan.canExecute || plan.document.steps.count == 1)
                        }.padding(.vertical, 3)
                    }.frame(height: 280)
                    if !plan.issues.isEmpty {
                        Text("以下语句尚不能转换，执行已禁用").foregroundStyle(.orange)
                        Text(plan.issues.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("导出计划 JSON…") { model.exportFlashPlan() }.disabled(!plan.canExecute)
                        Button("生成 Mac 脚本…") { model.exportFlashShell() }.disabled(!plan.canExecute)
                        Spacer()
                        Button("检查设备并审阅…") { model.reviewFlashPlan() }.buttonStyle(.borderedProminent).disabled(!model.fastbootReady || !plan.canExecute)
                    }
                    Text("目录生成按文件名排序，请先核对顺序。机型及防回滚未声明时需人工确认。执行前复制全部镜像；跨模式目标的容量在对应阶段、写入之前检查。逻辑分区操作需要 FastbootD，所有命令绑定确认的序列号。新增能力尚未验收。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
