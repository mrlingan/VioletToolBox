import SwiftUI
import VioletCore

struct OujiaFlashView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Set<String>> private var selected = []
    @ViewState<String> private var search = ""
    @ViewState<OujiaMode> private var mode = .standard
    @ViewState<OujiaPlatform> private var platform = .qualcomm
    @ViewState<String> private var targetSlot = "a"
    @ViewState<Bool> private var clearData = false
    @ViewState<Bool> private var reboot = false
    @ViewState<Bool> private var protect = true
    @ViewState<String> private var arbSlot = "a"
    var visible: [OujiaImage] { (model.oujiaPackage?.images ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "欧加全量包线刷", icon: "arrow.triangle.branch") {
                HStack {
                    Button("选择本地镜像目录…") { model.openOujiaPackage() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("全选可见项") { selected.formUnion(visible.map(\.id)) }
                    Button("取消选择") { selected = [] }
                }
                Text("接受包目录或含 images 子目录的解包结果。Payload / OFP / OPS 可先在相应页面提取。本入口目前覆盖本地全量镜像编排，云端提取与售后 XML 仍在移植。").font(.caption).foregroundStyle(.secondary)
                if let package = model.oujiaPackage {
                    Text(package.root.path).font(.caption).textSelection(.enabled)
                    TextField("搜索镜像", text: $search).textFieldStyle(.roundedBorder)
                    List(visible) { image in
                        HStack {
                            Toggle(image.name, isOn: Binding(get: { selected.contains(image.id) }, set: { if $0 { selected.insert(image.id) } else { selected.remove(image.id) } })).toggleStyle(.checkbox).frame(width: 210, alignment: .leading)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: image.byteCount), countStyle: .file)).font(.caption).frame(width: 110, alignment: .trailing)
                            Text(image.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 3)
                    }.frame(height: 260)
                    Picker("模式", selection: $mode) { ForEach(OujiaMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    HStack {
                        Picker("平台", selection: $platform) { ForEach(OujiaPlatform.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("目标活动槽", selection: $targetSlot) { Text("A").tag("a"); Text("B").tag("b") }.disabled(mode == .standard || mode == .rebuild)
                    }
                    Toggle("保护 persist / OCDT / 校准及基带数据镜像", isOn: $protect).toggleStyle(.checkbox)
                    HStack {
                        Toggle("完成后清除 metadata / userdata", isOn: $clearData).toggleStyle(.checkbox)
                        Toggle("完成后重启", isOn: $reboot).toggleStyle(.checkbox)
                    }
                    Text("标准模式使用当前槽；强力模式重建所选逻辑分区到 A 槽；AB 通刷先完成双槽非逻辑分区，再处理目标槽逻辑分区。强力 / AB / 仅 FastbootD 需要 my_company 与 my_preload。全部模式包含 COW 清理和末尾 FRP 擦除，确认窗口会列出这些步骤。").font(.caption).foregroundStyle(.secondary)
                    Button("生成批量线刷计划") {
                        var config = OujiaFlashConfiguration(); config.mode = mode; config.platform = platform; config.targetSlot = targetSlot
                        config.clearData = clearData; config.reboot = reboot; config.protectCalibration = protect
                        model.makeOujiaFlashPlan(selected: selected, configuration: config)
                    }.buttonStyle(.borderedProminent).disabled(!model.fastbootReady || selected.isEmpty)
                    Text("生成时只读设备分区表、当前模式和槽位；生成后到「批量线刷」审阅与执行。设备平台需由 lk / xbl 分区特征与所选平台一致，目标分区不作模糊匹配。本轮实现尚未编译、测试或实机验收。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Card(title: "xbl_config · ARB 镜像索引", icon: "number.square") {
                HStack {
                    Button("分析本地 xbl_config…") { model.openXBLARB() }
                    Picker("设备槽位", selection: $arbSlot) { Text("A").tag("a"); Text("B").tag("b") }.frame(width: 150)
                    Button("ADB Root 回读并分析") { model.readDeviceXBLARB(slot: arbSlot) }.disabled(!model.adbReady)
                }
                Text("读取小端 ELF64 中最后一个非空 PT_NULL 段的 OEM 元数据，与 Windows 解析字段一致。设备入口只回读所选槽位的 xbl_config；该结果是镜像索引，不等同于直接读取硬件熔丝。").font(.caption).foregroundStyle(.secondary)
                if let arb = model.xblARB {
                    Text(model.xblARBSource).font(.caption).textSelection(.enabled)
                    HStack {
                        Text("Major \(arb.majorVersion)"); Text("Minor \(arb.minorVersion)")
                        Text("ARB \(arb.index)").fontWeight(.semibold)
                    }.font(.system(.body, design: .monospaced))
                    Text("HASH 偏移 \(arb.hashSegmentOffset) · OEM 偏移 \(arb.oemMetadataOffset)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.onChange(of: model.oujiaPackage?.root) { _ in selected = Set(model.oujiaPackage?.images.map(\.id) ?? []) }
    }
}

extension AppModel {
    func openXBLARB() {
        guard let file = chooseFiles().first else { return }
        perform("分析 xbl_config ARB") {
            let control = self.workControl
            let result = try await Task.detached { try XBLARBImage.inspect(file, control: control) }.value
            try control.check(); self.xblARB = result; self.xblARBSource = file.path
            self.append("xbl_config OEM 元数据：\(result.majorVersion).\(result.minorVersion)，ARB 索引 \(result.index)。")
        }
    }
    func readDeviceXBLARB(slot: String) {
        guard ["a","b"].contains(slot), let device = selected, device.shellReady else { return }
        perform("回读 xbl_config ARB") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("violet-arb-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let response = try await self.execute("adb", RootModuleCommands.shell(PartitionCommands.listADB), device: device, timeout: 120, binary: true)
            let partitions = try PartitionCommands.parseADB(response.stdout)
            guard let partition = partitions.first(where: { $0.name == "xbl_config_" + slot }) ?? partitions.first(where: { $0.name == "xbl_config" }) else { throw InputError.invalid("未找到所选槽位的 xbl_config 分区。") }
            let file = directory.appendingPathComponent(partition.name + ".img")
            _ = try await self.executeStream(PartitionCommands.readRaw(partition), device: device, to: file, expectedSize: partition.size)
            let control = self.workControl
            let result = try await Task.detached { try XBLARBImage.inspect(file, control: control) }.value
            try control.check(); self.xblARB = result; self.xblARBSource = "设备 \(device.serial) / \(partition.name)"
            self.append("已回读并分析 \(partition.name)，ARB 镜像索引 \(result.index)。")
        }
    }
    func openOujiaPackage() {
        guard let folder = chooseFiles(directories: true).first else { return }
        perform("读取欧加镜像目录") {
            let control = self.workControl
            let package = try await Task.detached { try OujiaPackage.open(folder, control: control) }.value
            try control.check(); self.oujiaPackage = package
            self.append("找到 \(self.oujiaPackage?.images.count ?? 0) 个候选镜像。")
        }
    }
    func makeOujiaFlashPlan(selected: Set<String>, configuration: OujiaFlashConfiguration) {
        guard let package = oujiaPackage, let device = self.selected, device.transport == .fastboot else { return }
        perform("生成欧加线刷计划") {
            let result = try await self.execute("fastboot", ["getvar","all"], device: device, timeout: 30, binary: true)
            let catalog = try FastbootPartitionCatalog.parse(result.text)
            let slot = try await self.readFlashVariable("current-slot", device: device).trimmingCharacters(in: CharacterSet(charactersIn: "_")).lowercased()
            let mode = try await self.readFlashVariable("is-userspace", device: device)
            guard ["yes","no"].contains(mode) else { throw InputError.invalid("设备模式响应无效。") }
            let control = self.workControl
            let plan = try await Task.detached { try OujiaFlashPlanner.make(package: package, selected: selected, catalog: catalog, currentSlot: slot, userspace: mode == "yes", configuration: configuration, control: control) }.value
            try control.check()
            self.flashPlan = plan; self.rawProgramImages = nil
            self.append("欧加计划已生成：\(plan.document.steps.count) 步。请在「批量线刷」页面审阅目标与全部删除 / 擦除步骤。")
        }
    }
}
