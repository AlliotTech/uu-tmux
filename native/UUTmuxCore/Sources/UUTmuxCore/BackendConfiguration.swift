import Foundation

/// 后端可执行文件与 socket 的统一来源。
/// 生产用默认路径；测试注入替代路径与独立 socket，绝不从 PATH 随意找 tmux。
public struct BackendConfiguration: Sendable, Equatable {
    public var cliURL: URL
    public var muxURL: URL
    public var socketURL: URL

    public init(cliURL: URL, muxURL: URL, socketURL: URL) {
        self.cliURL = cliURL
        self.muxURL = muxURL
        self.socketURL = socketURL
    }

    /// UU 的默认安装路径；socket 基于当前用户 home 解析。
    public static func standard(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> BackendConfiguration {
        let helpers = URL(fileURLWithPath: "/Applications/UURemote.app/Contents/Helpers")
        return BackendConfiguration(
            cliURL: helpers.appendingPathComponent("uuyc-cli"),
            muxURL: helpers.appendingPathComponent("tmux/uuyc-mux"),
            socketURL: home
                .appendingPathComponent("Library/Application Support/UURemote/tmux.sock")
        )
    }

    /// mux 命令统一带上 `-S <socket>`。
    public var muxSocketArguments: [String] { ["-S", socketURL.path] }
}
