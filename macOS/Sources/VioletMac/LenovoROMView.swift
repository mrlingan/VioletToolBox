import SwiftUI
import AppKit
import VioletCore

struct LenovoROMView: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var input = ""
    @ViewState<String> private var preset = ""
    var body: some View {
        Card(title: "联想 SN / MTM 查包", icon: "shippingbox") {
            HStack {
                TextField("8 位 SN 或 10 位 MTM", text: $input).textFieldStyle(.roundedBorder)
                Button("查询") { model.queryLenovoROM(input) }.disabled(input.isEmpty)
            }
            HStack {
                Picker("预设机型", selection: $preset) {
                    Text("选择 Y700 机型").tag("")
                    ForEach(LenovoROMClient.presets) { item in Text("\(item.name) · \(item.mtm)").tag(item.mtm) }
                }
                Button("查询预设") { input = preset; model.queryLenovoROM(preset) }.disabled(preset.isEmpty)
            }
            Text("SN 会提交给联想查询服务，用于解析机器 MTM；也可直接使用 MTM 查询固件。").font(.caption).foregroundStyle(.secondary)
            if let result = model.lenovoROM {
                Text(result.summary).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("复制查询结果") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.summary, forType: .string) }
                    if let url = result.firmware?.downloadURL {
                        Button("复制下载地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                        Button("准备下载…") { model.useLenovoROM(url) }
                    }
                }
            }
        }
    }
}

extension AppModel {
    func queryLenovoROM(_ input: String) {
        do {
            let value = try LenovoROMClient.normalizedInput(input)
            perform("联想查包") {
                self.lenovoROM = nil
                let result = try await LenovoROMClient().query(value)
                try self.workControl.check(); self.lenovoROM = result
                self.append(result.firmware == nil ? "联想未返回可用刷机包，详情见查询页面。" : "已取得联想刷机包信息。")
            }
        } catch { self.error = error.localizedDescription }
    }
    func useLenovoROM(_ url: URL) {
        downloadSource = url.absoluteString; downloadHeaders = [:]; downloadDestination = nil
        chooseDownloadDestination()
    }
}
