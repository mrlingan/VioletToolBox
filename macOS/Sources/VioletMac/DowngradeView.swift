import SwiftUI
import AppKit
import VioletCore

struct DowngradeView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Int> private var selectedPackage = -1
    var package: DowngradePackage? { model.downgradeCatalog?.packages.first { $0.id == selectedPackage } }
    var body: some View {
        VStack(spacing:20) {
            Card(title:"ColorOS / 一加降级助手",icon:"arrow.down.app") {
                Text("沿用 Windows 版流程：连接手机端降级助手、查询可用版本、下载或选择本地包，再推送并提交安装请求。").foregroundStyle(.secondary)
                Text("适用条件：Windows 版说明仅用于已熔断的 OPPO / 一加跨安卓版本降级；未熔断设备可能产生不可逆熔断。降级会清空数据，开始前请备份。").font(.callout).foregroundStyle(.orange)
                HStack {
                    Link("下载降级助手 APK",destination:URL(string:"https://wwauy.lanzouv.com/i7s3z3l8dmve")!)
                    Button("选择已下载的 APK…") { model.chooseDowngradeAPK() }
                    if model.downgradeAPK != nil { Button("使用手机已安装版本") { model.downgradeAPK = nil } }
                }
                Text(model.downgradeAPK?.path ?? "未选择 APK：查询时使用手机已安装的 com.color.otaassistant。").font(.caption).textSelection(.enabled)
                Button("查询可用降级版本…") { model.queryDowngrade() }.buttonStyle(.borderedProminent).disabled(!model.adbReady)
                Text("若没有可用版本，请先让手机联网并手动检查一次系统更新，再重新查询。查询需要将设备信息提交给 ColorOS 服务。").font(.caption).foregroundStyle(.secondary)
            }
            if let catalog = model.downgradeCatalog {
                Card(title:"可用降级版本",icon:"list.bullet.rectangle") {
                    Text("\(catalog.device.model) · \(catalog.device.colorOSVersion) · \(catalog.device.androidVersion)")
                    Text("当前 OTA：\(catalog.device.otaVersion)").font(.caption).textSelection(.enabled)
                    Text("设备：\(model.downgradeDevice?.serial ?? "") · 查询于 \(catalog.created.formatted())").font(.caption).foregroundStyle(.secondary)
                    if catalog.packages.isEmpty { Text("查询未返回可用降级包。").foregroundStyle(.secondary) }
                    ForEach(catalog.packages) { item in
                        HStack(alignment:.top) {
                            Toggle(isOn:Binding(get:{ selectedPackage == item.id },set:{ if $0 { selectedPackage = item.id } else if selectedPackage == item.id { selectedPackage = -1 } })) {
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(item.colorOSVersion) · \(item.androidVersion)").font(.headline)
                                    Text(item.otaVersion).font(.caption).textSelection(.enabled)
                                    Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:item.fileSize),countStyle:.file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                            Spacer()
                        }
                        Divider()
                    }
                    if let package {
                        Text("MD5：\(package.md5.isEmpty ? "服务端未提供" : package.md5)").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        HStack {
                            Button("下载并校验…") { model.downloadDowngrade(package) }
                            Button("解析云端版本详情") { model.readDowngradeVersion(package) }
                            Button("复制下载地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(package.url.absoluteString,forType:.string) }
                        }
                        if model.downgradeVersionPackage == package.id, let version = model.downgradeVersion {
                            Text(version.summary).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            Card(title:"本地包与手机安装",icon:"iphone.and.arrow.forward") {
                Button("选择本地降级包…") { model.chooseDowngradePackage() }
                Text(model.downgradeLocalPackage?.path ?? "尚未选择本地降级包。").font(.caption).textSelection(.enabled)
                Button("推送并提交所选版本…") { if let package { model.reviewDowngradeInstall(package) } }
                    .buttonStyle(.borderedProminent).disabled(package == nil || model.downgradeLocalPackage == nil || !model.adbReady)
                Text("安装前重新核对设备当前版本与服务端签名数据。本地包和手机端文件均核对大小 / MD5，文件保存在唯一命名的内部存储路径。助手回应成功后，仍需在手机软件更新中完成本地安装。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of:model.downgradeCatalog?.id) { _ in selectedPackage = model.downgradeCatalog?.packages.first?.id ?? -1 }
    }
}
