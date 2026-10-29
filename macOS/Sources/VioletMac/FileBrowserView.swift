import SwiftUI
import VioletCore

struct FileBrowserCard: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var directory = "/sdcard"
    @ViewState<Set<String>> private var selection = []
    @ViewState<Bool> private var showName = false
    @ViewState<String> private var name = ""
    @ViewState<String> private var mode = "folder"
    var files: [RemoteFile] { model.remoteFiles.filter { selection.contains($0.id) } }
    var body: some View {
        Card(title: "设备文件浏览器", icon: "folder") {
            HStack {
                TextField("设备绝对路径", text: $directory).textFieldStyle(.roundedBorder).onSubmit { browse(directory) }
                Button("加载目录") { browse(directory) }
                Button("上级") { browse((model.remoteDirectory as NSString).deletingLastPathComponent) }.disabled(model.remoteDirectory == "/")
            }
            List(model.remoteFiles, selection: $selection) { file in
                HStack {
                    Image(systemName: file.kind == .directory ? "folder" : file.kind == .link ? "link" : "doc")
                    Text(file.name).lineLimit(1)
                    Spacer()
                    if file.kind == .file { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).foregroundStyle(.secondary).font(.caption) }
                    if file.kind == .directory { Button("打开") { browse(file.path) }.buttonStyle(.borderless) }
                }.tag(file.path).padding(.vertical, 3)
            }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8))
            Text("\(model.remoteDirectory) · \(model.remoteFiles.count) 个项目 · 选中 \(files.count) 项").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("新建文件夹…") { mode = "folder"; name = ""; showName = true }
                Button("新建文件…") { mode = "file"; name = ""; showName = true }
                Button("重命名…") { mode = "rename"; name = files.first?.name ?? ""; showName = true }.disabled(files.count != 1)
                Button("接收所选…") { model.receiveRemoteFiles(files) }.disabled(files.isEmpty)
                Button("删除…", role: .destructive) { model.deleteRemoteFiles(files) }.disabled(files.isEmpty)
            }
            if files.count == 1, let file = files.first, file.name.lowercased().hasSuffix(".apk") {
                Button("安装所选 APK…") { model.installDeviceAPK(file) }
            }
            Text("按住 ⌘ 或 ⇧ 多选。支持设备普通用户可访问的目录；文件名以编码传输，特殊符号不会作为命令执行。已有同名文件不会被新建或重命名覆盖。").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: model.remoteDirectory) { value in directory = value; selection = [] }
            .onChange(of: model.selectedID) { _ in selection = []; directory = "/sdcard" }
            .sheet(isPresented: $showName) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(mode == "rename" ? "重命名" : mode == "folder" ? "新建文件夹" : "新建文件").font(.headline)
                    TextField("名称", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer(); Button("取消") { showName = false }
                        Button("保存") { model.editRemoteFile(name: name, folder: mode == "folder", rename: mode == "rename" ? files.first : nil); showName = false }.buttonStyle(.borderedProminent).disabled(name.isEmpty)
                    }
                }.padding(24).frame(width: 420)
            }
    }
    func browse(_ path: String) { selection = []; model.browseDeviceFiles(path) }
}
