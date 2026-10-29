import SwiftUI
import VioletCore

struct RemoteFirmwareView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing:20) {
            Card(title:"在线 OTA / ZIP",icon:"network") {
                TextField("HTTP / HTTPS OTA ZIP 或 payload.bin 地址",text:Binding(get:{model.remoteFirmwareSource},set:{ model.remoteFirmwareSource = $0; model.remoteFirmwareHeaders = [:] })).textFieldStyle(.roundedBorder)
                HStack {
                    Button("读取远程目录") { model.openRemoteFirmware() }.buttonStyle(.borderedProminent).disabled(model.remoteFirmwareSource.isEmpty)
                    if !model.remoteFirmwareHeaders.isEmpty { Button("清除资源请求头") { model.remoteFirmwareHeaders = [:] } }
                }
                Text("使用 Range 读取目录与所选镜像，支持 ZIP64。远程 payload.bin 在 ZIP 内须为 Stored（未压缩）；普通 ZIP 文件支持 Stored / Deflate。可从 ROM 资源页面携带请求头打开。").font(.caption).foregroundStyle(.secondary)
            }
            RemoteFirmwareResultView()
        }
    }
}

struct RemoteFirmwareResultView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var filesMode = false
    @ViewState<Set<String>> private var selectedPartitions = []
    @ViewState<Set<String>> private var selectedFiles = []
    @ViewState<String> private var search = ""
    var body: some View {
        if let archive = model.remoteFirmware {
            Card(title:"远程内容",icon:"shippingbox") {
                Text(archive.url.lastPathComponent.isEmpty ? "远程资源" : archive.url.lastPathComponent).font(.system(.caption,design:.monospaced))
                Text("完整资源大小：" + ByteCountFormatter.string(fromByteCount:Int64(clamping:archive.size),countStyle:.file)).font(.caption).foregroundStyle(.secondary)
                if !archive.hasValidator { Text("服务端未提供强 ETag / 修改时间。读取时复核目录 / manifest，并检查已有 CRC / SHA-256；这些摘要不等同厂商签名。").font(.caption).foregroundStyle(.orange) }
                ForEach(Array(archive.diagnostics.enumerated()),id:\.offset) { _, diagnostic in Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let version = archive.version {
                    Text(version.summary).font(.caption).textSelection(.enabled)
                    Button("保存原始 metadata…") { model.saveRemoteVersionMetadata() }
                }
                if archive.payload != nil && archive.zip != nil {
                    Picker("读取内容",selection:$filesMode) { Text("Payload 分区").tag(false); Text("ZIP 文件").tag(true) }.pickerStyle(.segmented)
                }
                TextField("筛选名称",text:$search).textFieldStyle(.roundedBorder)
                if !filesMode, let payload = archive.payload {
                    HStack {
                        Button("选择可提取分区") { selectedPartitions = Set(payload.partitions.filter(\.extractable).map(\.name)) }
                        Button("清空") { selectedPartitions = [] }
                    }
                    List(payload.partitions.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) },selection:$selectedPartitions) { item in
                        HStack {
                            Text(item.name).font(.system(.body,design:.monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:item.size),countStyle:.file)).font(.caption)
                            Text(item.extractable ? (item.hasSHA256 ? "SHA-256" : "无分区摘要") : item.requiresSource ? "需要旧镜像" : "不支持操作 \(item.unsupportedTypes.map(String.init).joined(separator:","))").font(.caption).foregroundStyle(item.extractable ? Color.secondary : .orange)
                        }.tag(item.name)
                    }.frame(height:250)
                    Button("提取所选 \(selectedPartitions.count) 个分区…") { model.extractRemoteFirmware(names:selectedPartitions,zipEntries:false) }
                        .buttonStyle(.borderedProminent).disabled(selectedPartitions.isEmpty || payload.partitions.contains { selectedPartitions.contains($0.name) && !$0.extractable })
                } else if let zip = archive.zip {
                    HStack {
                        Button("选择可提取文件") { selectedFiles = Set(zip.entries.filter(\.extractable).map(\.name)) }
                        Button("清空") { selectedFiles = [] }
                    }
                    List(zip.entries.filter { !$0.isDirectory && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) },selection:$selectedFiles) { item in
                        HStack {
                            Text(item.name).font(.system(.caption,design:.monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:item.size),countStyle:.file)).font(.caption)
                            Text(item.unsupportedReason ?? (item.method == 0 ? "Stored · CRC32" : "Deflate · CRC32")).font(.caption).foregroundStyle(item.extractable ? Color.secondary : .orange)
                        }.tag(item.name)
                    }.frame(height:250)
                    Button("提取所选 \(selectedFiles.count) 个文件…") { model.extractRemoteFirmware(names:selectedFiles,zipEntries:true) }
                        .buttonStyle(.borderedProminent).disabled(selectedFiles.isEmpty || zip.entries.contains { selectedFiles.contains($0.name) && !$0.extractable })
                }
                Text("输出保存在新建文件夹；取消或错误会移除当前半成品，已完成文件保留。不会自动刷入手机。").font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of:archive.id) { _ in reset(archive) }
            .onAppear { reset(archive) }
        }
    }
    private func reset(_ archive: RemoteFirmwareArchive) {
        selectedPartitions = []; selectedFiles = []; search = ""; filesMode = archive.payload == nil
    }
}
