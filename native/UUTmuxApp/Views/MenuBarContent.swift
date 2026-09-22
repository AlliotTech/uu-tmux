import SwiftUI
import UUTmuxCore

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        Divider()

        // 少量最近会话（按创建时间取末尾几条）。
        ForEach(model.store.sessions.suffix(5)) { s in
            Text(s.displayName)
        }

        Divider()

        Button("打开管理窗口") { openWindow(id: "manager") }
        Button("刷新") { model.refreshNow() }
        Toggle("为外部新会话自动开窗", isOn: Bindable(model).autoMirror)
        Toggle("登录时启动", isOn: Bindable(model).launchAtLogin)
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
    }

    private var statusLine: String {
        switch model.store.status {
        case .unknown: return "正在连接…"
        case .ok(let n): return "已连接 · \(n) 个会话"
        case .socketMissing: return "UU 无 socket · 可新建首个会话"
        case .cliMissing: return "未找到 UU"
        case .stale(let r): return "暂时无法刷新 · \(r)"
        }
    }
}
