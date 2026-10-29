import SwiftUI
import AppKit
import VioletCore

struct PayloadView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Set<String>> private var selected = []
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "Payload 分区提取", icon: "shippingbox") {
                Text("打开本地全量 OTA ZIP 或 payload.bin，按需提取 boot、init_boot、vendor_boot 等镜像。").foregroundStyle(.secondary)
                Button("打开 OTA / Payload…") { model.openPayload() }.buttonStyle(.borderedProminent)
                if let payload = model.payload {
                    Text(payload.originalURL.lastPathComponent).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Text("\(payload.partitions.count) 个分区 · " + ByteCountFormatter.string(fromByteCount: Int64(payload.fileSize), countStyle: .file)).foregroundStyle(.secondary)
                        Spacer()
                        Button("选择可提取分区") { selected = Set(payload.partitions.filter(\.extractable).map(\.name)) }
                        Button("清空") { selected = [] }
                    }.font(.caption)
                    List(payload.partitions, selection: $selected) { partition in
                        HStack {
                            Image(systemName: partition.extractable ? "internaldrive" : "exclamationmark.triangle").foregroundStyle(partition.extractable ? .purple : .orange)
                            Text(partition.name).font(.system(.body, design: .monospaced)).frame(width: 145, alignment: .leading)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(partition.size), countStyle: .file)).foregroundStyle(.secondary)
                            Spacer()
                            Text(partition.extractable ? (partition.hasSHA256 ? "可提取 · SHA-256" : "可提取") : partition.requiresSource ? "需要旧镜像" : "不支持操作 \(partition.unsupportedTypes.map(String.init).joined(separator: ","))")
                                .font(.caption).foregroundStyle(partition.extractable ? Color.secondary : .orange)
                        }.padding(.vertical, 4).tag(partition.name)
                    }.frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("提取所选 \(selected.count) 个分区…") { model.extractPayload(names: selected) }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty || payload.partitions.contains { selected.contains($0.name) && !$0.extractable })
                }
                Text("支持 REPLACE / BZip2 / XZ / ZSTD / ZERO / DISCARD。ZIP 会先解压到临时目录，需要额外磁盘空间。源镜像差分和未知操作会标出；输出不会覆盖已有镜像。ZSTD 与本轮共享读取代码尚未验收。").font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "提取与校验", icon: "checkmark.shield") {
                Text("有 SHA-256 字段时，校验操作数据及最终分区镜像。校验失败、取消或磁盘写入失败会移除当前分区的半成品；此前完成的镜像保留。校验不等同于验证厂商签名。").foregroundStyle(.secondary)
            }
            RemoteFirmwareView()
            Card(title:"本地 OTA 版本信息",icon:"doc.text.magnifyingglass") {
                Button("打开 OTA ZIP 的 metadata…") { model.openLocalFirmwareVersion() }
                if let version = model.localFirmwareVersion {
                    Text(model.localFirmwareVersionSource).font(.caption).textSelection(.enabled)
                    Text(version.summary).font(.caption).textSelection(.enabled)
                    Button("保存原始 metadata…") { model.saveFirmwareMetadata(version) }
                }
            }
        }.onChange(of: model.payload?.sourceURL) { _ in selected = [] }
    }
}

struct DownloadView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "文件下载与续传", icon: "arrow.down.circle") {
                TextField("HTTP / HTTPS 下载地址", text: Binding(get: { model.downloadSource }, set: { value in
                    model.downloadSource = value; model.downloadHeaders = [:]
                })).textFieldStyle(.roundedBorder)
                HStack {
                    Text(model.downloadDestination?.path ?? "尚未选择保存位置").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("保存到…") { model.chooseDownloadDestination() }
                }
                HStack {
                    Button("开始 / 继续下载") { model.startDownload() }.buttonStyle(.borderedProminent)
                        .disabled(model.downloadSource.isEmpty || model.downloadDestination == nil)
                    Button("清除 ROM 请求头") { model.downloadHeaders = [:] }.disabled(model.downloadHeaders.isEmpty)
                }
                if !model.downloadHeaders.isEmpty { Text("已携带 ROM 服务返回的 \(model.downloadHeaders.count) 项请求头，手动修改地址后会清除。").font(.caption).foregroundStyle(.secondary) }
                Text("点击底部「停止」可暂停。再次选择相同目标文件继续下载；链接过期时可替换地址，保留同一保存位置。续传要求服务器支持 Range，并提供相同的 ETag 或修改时间。").font(.callout).foregroundStyle(.secondary)
            }
            Card(title: "下载文件保留规则", icon: "doc.badge.clock") {
                Text("片段保存为「文件名.violet-part」，续传信息保存在旁边的 JSON 文件。退出应用后仍可继续；重新打开时填写地址并选择相同保存位置即可。下载完成后才改为最终文件名。").foregroundStyle(.secondary)
                Text("当前为单连接续传。已有完整文件不会被覆盖；文件标识变化或服务端忽略 Range 时会停止，避免拼接损坏的 ROM。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ROMView: View {
    @EnvironmentObject var model: AppModel
    let brands = ["OPPO", "OnePlus", "Realme", "Xiaomi", "Redmi", "魅族"]
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "ROM 资源", icon: "externaldrive.badge.icloud") {
                Text("查询 VioletToolBox 原有 ROM 服务，选择系列、机型和版本后获取下载地址。").foregroundStyle(.secondary)
                HStack {
                    Picker("包类型", selection: $model.romSelection.packageType) { Text("全量包").tag("full"); Text("售后包").tag("afterSales") }
                    Picker("品牌", selection: $model.romSelection.brand) { ForEach(brands, id: \.self) { Text($0).tag($0) } }
                }
                selector("系列", value: $model.romSelection.series, items: model.romSeries, action: { model.queryROM("series") })
                selector("机型", value: $model.romSelection.device, items: model.romDevices, action: { model.queryROM("devices") }, disabled: model.romSelection.series.isEmpty)
                selector("版本", value: $model.romSelection.version, items: model.romVersions, action: { model.queryROM("versions") }, disabled: model.romSelection.device.isEmpty)
                Button("获取下载地址") { model.queryROMLinks() }.buttonStyle(.borderedProminent).disabled(model.romSelection.version.isEmpty)
                Text("各品牌支持的包类型由服务端决定。此页面仅查询资源，不会自动刷写设备。").font(.caption).foregroundStyle(.secondary)
            }
            LenovoROMView()
            if let links = model.romLinks {
                Card(title: "可用下载地址", icon: "link") {
                    ForEach(links.items) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.label).font(.headline)
                            Text(item.url.absoluteString).font(.system(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            HStack {
                                Button("准备下载…") { model.useROMLink(item) }
                                Button("在线读取分区 / ZIP") { model.useRemoteROMLink(item) }
                                Button("复制地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.absoluteString, forType: .string) }
                            }
                        }
                        if item.id != links.items.last?.id { Divider() }
                    }
                    Text("「准备下载」填入下载页面；「在线读取」在下方显示内容。两者均携带资源服务返回的请求头。").font(.caption).foregroundStyle(.secondary)
                }
            }
            RemoteFirmwareResultView()
        }
        .onChange(of: model.romSelection.brand) { _ in model.resetROM(from: "brand") }
        .onChange(of: model.romSelection.packageType) { _ in model.resetROM(from: "brand") }
        .onChange(of: model.romSelection.series) { _ in model.resetROM(from: "series") }
        .onChange(of: model.romSelection.device) { _ in model.resetROM(from: "device") }
        .onChange(of: model.romSelection.version) { _ in model.romLinks = nil }
    }
    func selector(_ title: String, value: Binding<String>, items: [String], action: @escaping () -> Void, disabled: Bool = false) -> some View {
        HStack {
            Picker(title, selection: value) {
                Text("请选择\(title)").tag("")
                ForEach(items, id: \.self) { Text($0).tag($0) }
            }
            Button("读取\(title)", action: action)
        }.disabled(disabled)
    }
}
