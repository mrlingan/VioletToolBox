import SwiftUI
import VioletCore

struct FirmwarePackageView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Set<String>> private var selected = []
    @ViewState<String> private var search = ""
    var visible: [FirmwareEntry] { model.firmwarePackage?.entries.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) } ?? [] }
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "OFP / OPS 固件解包", icon: "shippingbox.and.arrow.backward") {
                Text("解析固件文件表，选择所需镜像和配置文件导出到 Mac。").foregroundStyle(.secondary)
                Button("打开 OFP / OPS…") { selected = []; search = ""; model.openFirmwarePackage() }.buttonStyle(.borderedProminent)
                if let document = model.firmwarePackage {
                    Text(document.sourceURL.lastPathComponent).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Text(document.format.label + " · \(document.entries.count) 个文件").foregroundStyle(.secondary)
                        Spacer()
                        Button("选择可见文件") { selected.formUnion(visible.map(\.path)) }
                        Button("清空") { selected = [] }
                    }.font(.caption)
                    TextField("搜索镜像或配置文件", text: $search).textFieldStyle(.roundedBorder)
                    List(visible, selection: $selected) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.encrypted ? "lock.doc" : "doc").foregroundStyle(.purple)
                            Text(entry.path).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(entry.path)
                    }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("导出所选 \(selected.count) 个文件…") { model.extractFirmwarePackage(names: selected) }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                }
                Text("支持传统高通 / 联发科 OFP，以及 OnePlus OPS MBox 4、5、6。加密 ZIP 封装和未知新密钥格式尚不支持。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "输出方式", icon: "folder.badge.gearshape") {
                Text("每次导出创建独立目录，并保留可用的 ProFile.xml / settings.xml。文件表越界、路径冲突或源文件变化时停止；取消会清理当前半成品，已完成文件保留。").foregroundStyle(.secondary)
                Text("解包只处理 Mac 本地文件，不会刷写手机。包内可能同时包含多个运营商 / 版本的 Super 分段，合并时应选择同一分组。").font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: model.firmwarePackage?.sourceURL) { _ in selected = [] }
    }
}

struct SuperImageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "Android Sparse → Raw", icon: "externaldrive.badge.plus") {
                Text("展开 Android Sparse 镜像，支持 RAW、FILL、DONT_CARE 和 CRC32 chunk。").foregroundStyle(.secondary)
                Button("打开 Sparse 镜像…") { model.openSparseImage() }
                if let image = model.sparseImage {
                    Text(image.sourceURL.lastPathComponent).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("\(image.chunkCount) chunks · block \(image.blockSize) bytes · 展开 " + ByteCountFormatter.string(fromByteCount: Int64(clamping: image.expandedSize), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    Text(image.hasCRC ? "包含 CRC32，展开时会验证。" : "未提供 CRC32，展开时验证文件结构和范围。").font(.caption).foregroundStyle(.secondary)
                    Button("保存展开后的 Raw 镜像…") { model.expandSparseImage() }.buttonStyle(.borderedProminent)
                }
            }
            Card(title: "分段 Super 合并", icon: "square.3.layers.3d") {
                Text("选择同版本的 super.0 / super.1 等分段。Sparse 按目标位置合并，Raw 按编号顺序拼接。").foregroundStyle(.secondary)
                Button("选择 Super 分段…") { model.chooseSuperSegments() }
                if !model.superFiles.isEmpty {
                    if !model.superVariants.isEmpty {
                        Picker("ProFile.xml 分组", selection: $model.superVariantID) {
                            Text("请选择同一运营商 / 版本").tag("")
                            ForEach(model.superVariants) { variant in Text(variant.name).tag(variant.id) }
                        }
                    }
                    let files = model.selectedSuperFiles
                    if !files.isEmpty {
                        ForEach(files, id: \.path) { file in Label(file.lastPathComponent, systemImage: "doc").font(.system(.caption, design: .monospaced)) }
                    } else { Text("已选择 \(model.superFiles.count) 个文件，请先选择映射分组。").font(.caption).foregroundStyle(.secondary) }
                    Button("合并并保存 super.img…") { model.mergeSuperSegments() }.buttonStyle(.borderedProminent).disabled(files.count < 2)
                }
                Text("检查编号连续性、Sparse 布局与重叠数据。重复内容允许重用，冲突内容会报错。输出不会覆盖源文件或已有镜像。").font(.caption).foregroundStyle(.secondary)
            }
            Text("本页提供镜像展开和分段合并，尚不包含 lpmake 分区重建。Raw 输出使用文件系统空洞保留零区域，显示的逻辑大小可能大于实际占用。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
