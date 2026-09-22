import Foundation

/// 快照数据源抽象。生产用 `TmuxBackend`；测试注入伪实现验证状态机。
public protocol SnapshotProviding: Sendable {
    func snapshot() async throws -> SessionSnapshot
}

/// 读取 UU 的 session/window/pane/client，组装只读快照。
/// 写操作定义在 BackendWrites.swift 的扩展中。
public struct TmuxBackend: SnapshotProviding, Sendable {
    public let config: BackendConfiguration
    public let runner: ProcessRunner
    public var queryTimeout: TimeInterval

    /// 字段分隔符：制表符。UU 内置 tmux 会把 0x1F 等控制字节转义成字面 `\037`，
    /// 但制表符原样输出（已实测）。每个格式串把唯一的自由文本字段放在最后，
    /// 用限定次数的切分让末字段吸收其中可能出现的制表符。
    /// ponytail: 名称/路径含制表符属极端情况且落在末字段，不会错位；真出现异常再加编码协议。
    static let sep = "\t"

    public init(config: BackendConfiguration,
                runner: ProcessRunner = ProcessRunner(),
                queryTimeout: TimeInterval = 3) {
        self.config = config
        self.runner = runner
        self.queryTimeout = queryTimeout
    }

    // MARK: - 服务实例

    public func readInstance() async throws -> BackendInstanceID {
        let fmt = ["#{pid}", "#{start_time}", "#{socket_path}"].joined(separator: Self.sep)
        let out = try await mux(["display-message", "-p", fmt])
        guard let line = firstNonEmptyLine(out) else { throw BackendError.commandFailed("display-message empty") }
        let f = fields(line, count: 3)
        guard f.count == 3, let pid = Int(f[0]), let start = Int(f[1]) else {
            throw BackendError.commandFailed("display-message parse: \(line)")
        }
        return BackendInstanceID(socketPath: f[2], serverPID: pid, startTime: start)
    }

    // MARK: - 快照

    /// 组装快照。前后各读一次服务实例，实例变化则丢弃本轮（避免把旧 ID 用到新服务）。
    public func snapshot() async throws -> SessionSnapshot {
        try ensureReachable()
        let instance = try await readInstance()

        async let sessionsRaw = mux(["list-sessions", "-F", sessionFormat])
        async let windowsRaw = mux(["list-windows", "-a", "-F", windowFormat])
        async let panesRaw = mux(["list-panes", "-a", "-F", paneFormat])
        async let clientsRaw = mux(["list-clients", "-F", clientFormat])

        let sessions = try await parseSessions(sessionsRaw, instance: instance)
        let windows = parseWindows(try await windowsRaw)
        let panes = parsePanes(try await panesRaw)
        let clients = parseClients(try await clientsRaw)

        // 再读一次实例，确认未在查询中途重启。
        let after = try await readInstance()
        guard after == instance else { throw BackendError.instanceChanged }

        let merged = sessions.map { s -> SessionInfo in
            var s = s
            // 主窗口：该会话 window_index 最小的窗口。
            let owned = windows.filter { $0.sessionID == s.key.sessionID }
                .sorted { $0.index < $1.index }
            if let primary = owned.first {
                s = s.withPrimaryWindow(id: primary.windowID, displayName: primary.name)
            }
            if let pane = panes.first(where: { $0.sessionID == s.key.sessionID && $0.windowActive && $0.paneActive }) {
                s.activePane = pane.pane
            }
            s.clients = clients.filter { $0.sessionID == s.key.sessionID }
            return s
        }
        return SessionSnapshot(instance: instance, observedAt: Date(), sessions: merged)
    }

    // MARK: - 可达性

    private func ensureReachable() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.cliURL.path) else { throw BackendError.cliMissing }
        guard fm.fileExists(atPath: config.socketURL.path) else { throw BackendError.socketMissing }
    }

    // MARK: - 命令

    private func mux(_ args: [String]) async throws -> String {
        let result: ProcessResult
        do {
            result = try await runner.run(executableURL: config.muxURL,
                                          arguments: config.muxSocketArguments + args,
                                          timeout: queryTimeout)
        } catch ProcessRunnerError.timedOut {
            throw BackendError.timedOut
        } catch {
            throw BackendError.commandFailed(String(describing: error))
        }
        guard result.exitCode == 0 else {
            throw BackendError.commandFailed("exit \(result.exitCode): \(result.stderrText)")
        }
        return result.stdoutText
    }

    // MARK: - 格式串

    private var sessionFormat: String {
        ["#{session_id}", "#{session_created}", "#{session_attached}", "#{session_windows}", "#{session_name}"]
            .joined(separator: Self.sep)
    }
    private var windowFormat: String {
        ["#{session_id}", "#{window_id}", "#{window_index}", "#{window_name}"].joined(separator: Self.sep)
    }
    private var paneFormat: String {
        ["#{session_id}", "#{window_active}", "#{pane_active}", "#{pane_id}", "#{pane_tty}",
         "#{pane_current_command}", "#{pane_current_path}"].joined(separator: Self.sep)
    }
    private var clientFormat: String {
        ["#{session_id}", "#{client_tty}", "#{client_pid}", "#{client_flags}"].joined(separator: Self.sep)
    }

    // MARK: - 解析（internal 便于测试）

    struct RawWindow { let sessionID: String; let windowID: String; let index: Int; let name: String }
    struct RawPane { let sessionID: String; let windowActive: Bool; let paneActive: Bool; let pane: PaneInfo }

    func parseSessions(_ text: String, instance: BackendInstanceID) throws -> [SessionInfo] {
        try lines(text).map { line in
            let f = fields(line, count: 5)
            guard f.count == 5, let created = Int(f[1]), let attached = Int(f[2]), let windows = Int(f[3]) else {
                throw BackendError.commandFailed("session parse: \(line)")
            }
            let key = SessionKey(instance: instance, sessionID: f[0], sessionCreated: created)
            return SessionInfo(key: key, tmuxSessionName: f[4], displayName: f[4],
                               primaryWindowID: "", attachedClientCount: attached, windowCount: windows,
                               activePane: nil, clients: [])
        }
    }

    func parseWindows(_ text: String) -> [RawWindow] {
        lines(text).compactMap { line in
            let f = fields(line, count: 4)
            guard f.count == 4, let idx = Int(f[2]) else { return nil }
            return RawWindow(sessionID: f[0], windowID: f[1], index: idx, name: f[3])
        }
    }

    func parsePanes(_ text: String) -> [RawPane] {
        lines(text).compactMap { line in
            let f = fields(line, count: 7)
            guard f.count == 7 else { return nil }
            let pane = PaneInfo(paneID: f[3], command: f[5], currentPath: f[6], tty: f[4])
            return RawPane(sessionID: f[0], windowActive: f[1] == "1", paneActive: f[2] == "1", pane: pane)
        }
    }

    func parseClients(_ text: String) -> [ClientInfo] {
        lines(text).compactMap { line in
            let f = fields(line, count: 4)
            guard f.count == 4, let pid = Int(f[2]) else { return nil }
            return ClientInfo(sessionID: f[0], tty: f[1], pid: pid, flags: f[3])
        }
    }

    /// 按分隔符切分，最多切成 count 段——末段吸收其中可能出现的分隔符。
    private func fields(_ line: String, count: Int) -> [String] {
        line.split(separator: Character(Self.sep), maxSplits: count - 1,
                   omittingEmptySubsequences: false).map(String.init)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    private func firstNonEmptyLine(_ text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    }
}

private extension SessionInfo {
    func withPrimaryWindow(id: String, displayName: String) -> SessionInfo {
        SessionInfo(key: key, tmuxSessionName: tmuxSessionName, displayName: displayName,
                    primaryWindowID: id, attachedClientCount: attachedClientCount,
                    windowCount: windowCount, activePane: activePane, clients: clients)
    }
}
