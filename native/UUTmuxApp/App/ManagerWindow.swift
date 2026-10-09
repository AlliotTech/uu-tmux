import AppKit
import SwiftUI

@MainActor
enum ManagerWindow {
    static let id = "manager"
    static weak var window: NSWindow?

    static func open(using openWindow: OpenWindowAction) {
        // 等菜单结束跟踪后再激活，避免菜单关闭时把焦点交还给原应用。
        DispatchQueue.main.async {
            openWindow(id: id)
            if let window {
                present(window)
            }
        }
    }

    static func present(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 使用真实的场景窗口，不依赖标题或 NSApp.keyWindow（可能是菜单或弹窗）。
struct ManagerWindowAccess: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            ManagerWindow.window = window
            // 首次 openWindow 创建窗口可能晚于菜单动作，挂接时完成展示。
            ManagerWindow.present(window)
        }
    }
}
