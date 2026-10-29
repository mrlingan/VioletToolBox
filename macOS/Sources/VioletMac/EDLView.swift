import SwiftUI
import VioletCore

struct EDLView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<EDLMemory> private var memory = .ufs
    @ViewState<String> private var lunText = "0,1,2,3,4,5,6,7"
    @ViewState<Set<String>> private var selected = []
    @ViewState<String> private var search = ""
    @ViewState<Bool> private var protect = true
    @ViewState<Bool> private var protectData = false
    @ViewState<UInt64> private var restoreLUN = 0
    @ViewState<URL?> private var mainGPT
    @ViewState<URL?> private var backupGPT
    var visible: [EDLPartitionTarget] { model.edlTargets.filter { search.isEmpty || $0.partition.name.localizedCaseInsensitiveContains(search) || "LUN\($0.geometry.lun)".localizedCaseInsensitiveContains(search) } }
    var ready: Bool { model.edlContext != nil }
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "EDL USB / Sahara / Firehose", icon: "cable.connector.horizontal") {
                HStack {
                    Button("扫描 EDL USB") { model.scanEDLDevices() }.buttonStyle(.borderedProminent)
                    Picker("目标", selection: $model.selectedEDLDeviceID) {
                        Text("选择设备").tag("")
                        ForEach(model.edlDevices) { device in Text(device.label).tag(device.id) }
                    }
                }
                Text("EDL 目标使用本页设备选择，不复用上方 ADB / Fastboot 设备。扫描只读取 USB 描述符；需要可用的 macOS qdl 和 violet-edl 工具。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("选择 Loader / Sahara XML…") { model.chooseEDLLoader() }
                    Button("读取芯片信息") { model.readEDLChipInfo() }.disabled(model.selectedEDLDevice == nil || ready)
                }
                if let loader = model.edlLoader {
                    Text(loader.sourceURL.path).font(.caption).textSelection(.enabled)
                    DisclosureGroup("\(loader.images.count) 个 Loader 镜像及 SHA-256") {
                        ForEach(loader.images, id: \.id) { image in
                            Text("ID \(image.id) · \(image.source.lastPathComponent) · \(image.size) bytes\n\(image.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Picker("存储", selection: $memory) { ForEach(EDLMemory.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }.frame(width: 160)
                    TextField("查询 LUN，例如 0,1,2,3", text: $lunText).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("审阅并发送 Loader…") { model.reviewEDLConnect(memory: memory, lunText: lunText) }.disabled(model.selectedEDLDevice == nil || model.edlLoader == nil)
                    Button("清除连接记录") { model.clearEDLContext() }.disabled(!ready)
                    Spacer()
                    if let context = model.edlContext { Text("已读取容量 · \(context.device.serial) · \(context.memory.rawValue)").font(.caption).foregroundStyle(.green) }
                }
                if !model.edlLastFailure.isEmpty { Text(model.edlLastFailure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if !model.edlChipInfo.isEmpty { DisclosureGroup("Sahara 芯片信息") { Text(model.edlChipInfo).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                Text("当前为通用 Firehose 后端，不会自动绕过或假定完成小米 / 欧加认证与 VIP。该批源码尚未编译、测试或连接实机；Windows 厂商认证与专用能力继续移植。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "物理 LUN / GPT 分区", icon: "rectangle.split.3x3") {
                ForEach(model.edlGeometries) { geometry in
                    HStack {
                        Text("LUN \(geometry.lun)").fontWeight(.medium)
                        Text("\(geometry.sectorSize) bytes / sector · \(geometry.totalSectors) sectors").font(.caption).foregroundStyle(.secondary)
                        Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: geometry.byteCount), countStyle: .file)).font(.caption)
                    }
                }
                HStack {
                    Button("读取并校验 GPT") { selected = []; model.readEDLGPT() }.disabled(!ready)
                    Button("导出已读 GPT…") { model.exportEDLGPT() }.disabled(!ready || model.edlVolumes.isEmpty)
                    Spacer()
                    Button("全选可见项") { selected.formUnion(visible.map(\.id)) }
                    Button("清空") { selected = [] }
                }
                TextField("搜索分区或 LUN", text: $search).textFieldStyle(.roundedBorder)
                List(visible) { target in
                    HStack {
                        Toggle(isOn: Binding(get: { selected.contains(target.id) }, set: { if $0 { selected.insert(target.id) } else { selected.remove(target.id) } })) {
                            Text("LUN\(target.geometry.lun) / \(target.partition.name)").font(.system(.caption, design: .monospaced))
                        }.toggleStyle(.checkbox).frame(width: 245, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: target.byteCount), countStyle: .file))
                            Text("LBA \(target.partition.firstLBA) + \(target.partition.sectorCount)").foregroundStyle(.secondary)
                        }.font(.caption).frame(width: 155, alignment: .leading)
                        Text(model.edlImages[target.id]?.lastPathComponent ?? "未选择写入镜像").font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("镜像…") { model.chooseEDLPartitionImage(target) }.buttonStyle(.borderless)
                    }.padding(.vertical, 3)
                }.frame(height: 300).disabled(!ready)
                Toggle("写入 / 擦除时保护校准及基带数据分区", isOn: $protect).toggleStyle(.checkbox)
                Toggle("写入 / 擦除时保护 userdata / metadata", isOn: $protectData).toggleStyle(.checkbox)
                Text("保护 persist、modemst1/2、fsg、fsc、oplusdycnvbk、oplusstanvbk；回读不受限制。写入先把 Sparse 展开为 Raw，输入末尾按物理扇区补零。操作前重新读取 GPT 并核对目标。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("回读所选…") { model.backupEDLPartitions(selected) }.disabled(!ready || selected.isEmpty)
                    Button("审阅写入…") { model.reviewEDLWrites(selected, protect: protect, protectData: protectData) }.disabled(!ready || selected.isEmpty)
                    Button("审阅擦除…") { model.reviewEDLErase(selected, protect: protect, protectData: protectData) }.disabled(!ready || selected.isEmpty)
                    Spacer()
                    Button("重启设备…") { model.reviewEDLReset() }.disabled(!ready)
                }
            }
            gptToolsCard
            EDLXMLFlashView(protect: protect, protectData: protectData)
        }
        .onChange(of: model.selectedEDLDeviceID) { _ in model.clearEDLContext(); model.edlChipInfo = ""; selected = [] }
        .onChange(of: memory) { _ in model.clearEDLContext(); selected = [] }
        .onChange(of: model.edlGeometries.map(\.id)) { ids in restoreLUN = ids.first ?? 0; mainGPT = nil; backupGPT = nil }
        .onChange(of: restoreLUN) { _ in model.edlRestoreVolume = nil }
    }
    var gptToolsCard: some View {
        Card(title: "GPT 恢复与 A/B 槽位", icon: "arrow.triangle.swap") {
            HStack {
                Button("读取当前槽位") { model.inspectEDLSlot() }.disabled(!ready)
                Text("当前：\(model.edlSlot.isEmpty ? "未识别" : model.edlSlot.uppercased())").font(.caption)
                Spacer()
                Button("切换 A…") { model.reviewEDLSlotChange(to: "a") }.disabled(!ready || model.edlVolumes.isEmpty)
                Button("切换 B…") { model.reviewEDLSlotChange(to: "b") }.disabled(!ready || model.edlVolumes.isEmpty)
            }
            Divider()
            Picker("恢复目标 LUN", selection: $restoreLUN) { ForEach(model.edlGeometries) { Text("LUN \($0.lun)").tag($0.lun) } }.frame(width: 190)
            HStack {
                Button("主 GPT 文件…") { if let file = model.chooseFiles().first { mainGPT = file; model.edlRestoreVolume = nil } }
                Text(mainGPT?.lastPathComponent ?? "未选择").font(.caption).lineLimit(1)
                Button("备份 GPT 文件…") { if let file = model.chooseFiles().first { backupGPT = file; model.edlRestoreVolume = nil } }
                Text(backupGPT?.lastPathComponent ?? "未选择").font(.caption).lineLimit(1)
            }
            HStack {
                Button("分析主备元数据") { model.importEDLGPTMetadata(lun: restoreLUN, main: mainGPT, backup: backupGPT) }.disabled(!ready || mainGPT == nil || backupGPT == nil)
                Button("审阅并恢复…") { model.reviewEDLRestoreGPT() }.disabled(!ready || model.edlRestoreVolume == nil)
            }
            if let volume = model.edlRestoreVolume {
                Text("LUN\(volume.id) · GUID \(volume.gpt.header.diskGUID) · \(volume.gpt.partitions.count) 个分区").font(.caption).textSelection(.enabled)
                if let warning = volume.gpt.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            }
            Text("恢复前备份将覆盖的原始区域；写回后逐字节回读核对。切槽沿用 Windows 的 GPT GUID / 属性规则，更新主备 CRC，再设置启动 LUN。整组 GPT 事务中请求停止会等待事务命令完成。此实现尚未验收。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
