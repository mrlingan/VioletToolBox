import SwiftUI
import AppKit

@main struct VioletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("紫罗兰工具箱") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1000, minHeight: 700)
                .tint(.purple)
                .task {
                    appDelegate.model = model
                    while !Task.isCancelled {
                        await model.refresh()
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("设备") {
                Button("刷新设备") { Task { await model.refresh(force: true) } }.keyboardShortcut("r")
                Button("安装 APK…") { model.installAPKs() }.disabled(!model.adbReady || model.busy)
                Button("截取屏幕…") { model.screenshot() }.disabled(!model.adbReady || model.busy)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy || model.mirroring {
            let alert = NSAlert()
            alert.messageText = "有操作正在运行"
            alert.informativeText = "退出会停止当前命令及投屏。停止刷写不会回滚已写入的数据。"
            alert.addButton(withTitle: "继续运行")
            alert.addButton(withTitle: "停止并退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
