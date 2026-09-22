import Foundation

/// 本地创建入口（uu-new / uut / GUI helper）报告自己的 TTY，使从 profile、命令行、
/// GUI 创建的会话都能被识别为本地操作，不被自动镜像误当外部会话开窗。
///
/// 约定：每个本地终端把自己的 TTY 追加一行到 markers 文件（append，原子行写入）。
/// App 读取全部 TTY，凡快照中某会话有客户端连在这些 TTY 上，即视为本地操作。
/// 陈旧行无害：TTY 不再对应任何会话客户端时自然失效。
public struct LocalTerminalMarkers: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("uu-tmux/local-terminals", isDirectory: false)
        }
    }

    /// 读取当前登记的 TTY 集合。
    public func ttys() -> Set<String> {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    /// 给定快照，返回属于本地终端的会话 key（客户端 TTY 命中 markers）。
    public func localSessionKeys(in snapshot: SessionSnapshot) -> Set<String> {
        let marked = ttys()
        guard !marked.isEmpty else { return [] }
        var keys: Set<String> = []
        for s in snapshot.sessions where s.clients.contains(where: { marked.contains($0.tty) }) {
            keys.insert(MirrorCoordinator.key(s))
        }
        return keys
    }
}
