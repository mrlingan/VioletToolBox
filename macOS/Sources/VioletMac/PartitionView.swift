import SwiftUI
import VioletCore

struct PartitionView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Set<String>> private var selected = []
    @ViewState<String> private var search = ""
    @ViewState<Bool> private var protect = true
    @ViewState<Bool> private var generateXML = false
    @ViewState<String> private var fileExtension = "img"
    @ViewState<UInt64> private var sectorSize = 512
    var visible: [DevicePartition] { model.devicePartitions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var selectedIDs: Set<String> { Set(model.devicePartitions.filter { selected.contains($0.id) }.map(\.id)) }
    var canReadTable: Bool { model.adbReady || model.fastbootReady }
    var body: some View {
        VStack(spacing: 20) { partitionCard; deviceGPTCard; localGPTCard }
            .onChange(of: model.selectedID) { _ in selected = [] }
    }
    var partitionCard: some View {
        Card(title: "设备分区", icon: "rectangle.split.3x3") {
            HStack {
                Button("读取当前设备分区表") { selected = []; model.readDevicePartitionTable() }.buttonStyle(.borderedProminent).disabled(!canReadTable)
                Button("匹配镜像目录…") { model.matchPartitionImages() }.disabled(!model.partitionTableReady)
                Button("匹配 XML…") { model.matchRawProgramPartitionImages() }.disabled(!model.partitionTableReady)
                Spacer()
                Button("选择可见项") { selected.formUnion(visible.map(\.id)) }.disabled(!model.partitionTableReady)
                Button("选已配镜像") { selected = Set(model.partitionImages.keys) }.disabled(!model.partitionTableReady || model.partitionImages.isEmpty)
                Button("清空") { selected = [] }
            }
            Text("ADB 从 by-name 目录读取实际块设备和容量，需要 Shell Root；Fastboot 从设备返回的 partition-size / partition-type 读取。操作前会重新核对目标分区。").font(.caption).foregroundStyle(.secondary)
            TextField("搜索分区名称", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Text("分区").frame(width: 170, alignment: .leading)
                Text("容量 / 类型").frame(width: 145, alignment: .leading)
                Text("写入镜像"); Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            List(visible) { partition in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { selected.contains(partition.id) }, set: { if $0 { selected.insert(partition.id) } else { selected.remove(partition.id) } })) {
                        Text(partition.name).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    }.toggleStyle(.checkbox).frame(width: 170, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: partition.size), countStyle: .file))
                        Text(partition.type).foregroundStyle(.secondary)
                    }.font(.caption).frame(width: 120, alignment: .leading)
                    if protect && PartitionCommands.protected(partition, adb: model.selected?.transport == .adb) {
                        Image(systemName: "lock.shield").foregroundStyle(.orange).help("写入 / 擦除时受保护，仍可回读")
                    }
                    Text(model.partitionImages[partition.id]?.lastPathComponent ?? "未选择").font(.caption).lineLimit(1).truncationMode(.middle)
                        .help(model.partitionImages[partition.id]?.path ?? partition.blockPath ?? partition.name)
                    Spacer(minLength: 4)
                    Button("镜像…") { model.choosePartitionImage(partition) }.buttonStyle(.borderless)
                }.padding(.vertical, 4)
            }.frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 8)).disabled(!model.partitionTableReady)
            HStack {
                Text("\(visible.count) / \(model.devicePartitions.count) 个分区 · 选中 \(selectedIDs.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("回读扩展名", selection: $fileExtension) { Text(".img").tag("img"); Text(".bin").tag("bin") }.frame(width: 170)
            }
            Toggle("保护基带、指纹及 ADB 数据分区", isOn: $protect).toggleStyle(.checkbox)
            Text("保护范围：modemst1/2、fsg、fsc、oplusdycnvbk、oplusstanvbk；ADB 模式还包含 userdata / metadata。").font(.caption).foregroundStyle(.secondary)
            Text("保护开启时，写入 / 擦除会跳过对应分区并在日志列出名称；回读不受限制。ADB 直接写入前会把 Sparse 展开为 Raw，Fastboot 使用原始 Sparse 文件。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("回读所选…") { model.backupDevicePartitions(selectedIDs, fileExtension: fileExtension, generateXML: generateXML && model.adbReady) }
                Button("审阅并写入…") { model.reviewPartitionWrites(selectedIDs, protect: protect) }.buttonStyle(.borderedProminent)
                Button("擦除所选…", role: .destructive) { model.reviewPartitionErase(selectedIDs, protect: protect) }
            }.disabled(!model.partitionTableReady || selectedIDs.isEmpty)
            Button("备份基带 / 指纹分区…") {
                model.backupDevicePartitions(Set(model.devicePartitions.filter(\.isBaseband).map(\.id)), fileExtension: fileExtension, generateXML: generateXML && model.adbReady)
            }.disabled(!model.partitionTableReady || !model.devicePartitions.contains(where: \.isBaseband))
            Text("回读按已知容量校验，失败 / 取消清理当前半成品，已完成文件保留。Fastboot fetch 依赖设备支持。写入 / 擦除停止会等待当前命令结束；强制退出不能回滚已写入数据。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var deviceGPTCard: some View {
        Card(title: "设备 GPT 备份", icon: "externaldrive.badge.checkmark") {
            Toggle("回读 / 备份时同时生成 rawprogram XML（ADB Root）", isOn: $generateXML).toggleStyle(.checkbox)
            Button("备份物理 GPT（ADB Root）…") { model.backupDeviceGPT(generateXML: generateXML) }.disabled(!model.adbReady)
            Text("自动探测 UFS / eMMC 物理块设备、LUN 与扇区大小。主备 header 和分区表 CRC32、主备一致性、分区范围及重叠检查通过后，保存 gpt_main / gpt_backup、几何清单和设备对应记录。XML 仅描述本次已验证的 GPT 区域，不会自动刷入。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var localGPTCard: some View {
        Card(title: "本地磁盘 GPT 分析", icon: "doc.text.magnifyingglass") {
            HStack {
                Picker("扇区 bytes", selection: $sectorSize) { ForEach([UInt64(512),1024,2048,4096,8192,16384,32768,65536], id: \.self) { Text(String($0)) } }.frame(width: 210)
                Button("打开完整磁盘镜像…") { model.openLocalGPT(sectorSize: sectorSize) }
            }
            if let image = model.localGPT {
                Text(model.localGPTURL?.lastPathComponent ?? "GPT").font(.system(.caption, design: .monospaced))
                Text("磁盘 GUID：\(image.header.diskGUID)\n\(image.totalSectors) sectors × \(image.sectorSize) bytes · \(image.partitions.count) 个分区").font(.caption).textSelection(.enabled)
                List(image.partitions) { partition in
                    HStack {
                        Text("\(partition.index)").foregroundStyle(.secondary).frame(width: 28)
                        Text(partition.name.isEmpty ? "<未命名>" : partition.name).frame(minWidth: 120, alignment: .leading)
                        Spacer()
                        Text("LBA \(partition.firstLBA)–\(partition.lastLBA)").foregroundStyle(.secondary)
                    }.font(.system(.caption, design: .monospaced)).padding(.vertical, 3)
                }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                if let warning = image.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                Button("导出已验证的主备 GPT 与分区清单…") { model.exportLocalGPT() }
            }
            Text("读取完整磁盘镜像中的主表与备份表，不修改磁盘。单独的 gpt_main.bin 不包含磁盘末尾备份区域，请使用完整磁盘镜像。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
