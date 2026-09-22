import Foundation

public enum CoordinatorError: Error, Equatable {
    case notConfirmed            // 15 秒内未能关联创建结果
    case targetGone              // 目标会话已消失
    case instanceChanged         // 服务实例变化，取消本次写入
    case ambiguousDisplayName    // 重名，CLI 无法唯一定位，拒绝
}

/// 串行化写操作，关联创建结果，协调刷新与窗口打开。
/// 写操作串行：同一时刻只有一个 create/attach/kill/rename 进行。
public actor SessionCoordinator {
    private let backend: TmuxBackend
    private let launcher: ITermLauncher
    private let operations: OperationStore
    /// 创建后等待 helper 报告 + list-clients 关联的上限。
    public var associationTimeout: TimeInterval
    /// 本应用登记的本地窗口绑定：SessionKey → iTerm2 窗口 id。
    /// 仅作可验证的提示，激活前必须核对 iTerm2 标识与 tmux 连接仍对应。
    private var windowBindings: [String: Int] = [:]

    public init(backend: TmuxBackend, launcher: ITermLauncher,
                operations: OperationStore, associationTimeout: TimeInterval = 15) {
        self.backend = backend
        self.launcher = launcher
        self.operations = operations
        self.associationTimeout = associationTimeout
    }

    // MARK: - 创建

    /// 结果：关联到的 SessionKey + UU 实际采用的显示名 + 窗口 id。
    public struct CreateOutcome: Sendable, Equatable {
        public let key: SessionKey
        public let displayName: String
        public let windowID: Int
        public let fellBackToDefaultProfile: Bool
    }

    /// 创建会话：写请求 → 开终端运行 helper → 用 helper 报告的 TTY 关联新会话。
    /// 不用“出现的第一个新 ID”或请求名称判断归属。
    public func create(name: String?, shell: String?, profileName: String?) async throws -> CreateOutcome {
        let req = OperationRequest(action: .create, name: name, shell: shell)
        try operations.writeRequest(req)

        let launch = try await launcher.openTerminal(operationID: req.id, profileName: profileName)

        let deadline = Date().addingTimeInterval(associationTimeout)
        while Date() < deadline {
            if let report = operations.readReport(req.id),
               let session = try await sessionForTTY(report.tty) {
                try? operations.remove(req.id)
                windowBindings[Self.bindingKey(session.key)] = launch.windowID
                return CreateOutcome(key: session.key, displayName: session.displayName,
                                     windowID: launch.windowID,
                                     fellBackToDefaultProfile: launch.fellBackToDefault)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        // 结果尚未确认：保留 request 供重启后核对，不自动重试创建。
        throw CoordinatorError.notConfirmed
    }

    /// 通过 list-clients 的 TTY 找到对应会话。
    private func sessionForTTY(_ tty: String) async throws -> SessionInfo? {
        let snap = try await backend.snapshot()
        return snap.sessions.first { s in s.clients.contains { $0.tty == tty } }
    }

    // MARK: - 结束

    /// 结束会话：重查目标存在且实例未变，再按 session_id 结束。
    /// 以原 SessionKey 消失作为本地完成条件，不因同名会话继续杀进程。
    public func terminate(_ key: SessionKey) async throws {
        let before = try await backend.snapshot()
        guard before.instance == key.instance else { throw CoordinatorError.instanceChanged }
        guard before.sessions.contains(where: { $0.key == key }) else { throw CoordinatorError.targetGone }

        try await backend.killSession(sessionID: key.sessionID)

        let after = try await backend.snapshot()
        // 实例变化不视为失败信息可信；实例一致时以 key 消失为准。
        if after.instance == key.instance,
           after.sessions.contains(where: { $0.key == key }) {
            throw CoordinatorError.targetGone // 仍在，视为未完成
        }
    }

    // MARK: - 重命名

    /// 重命名：CLI 以显示名为目标，重名则拒绝（不猜测）。
    public func rename(_ key: SessionKey, to newName: String) async throws {
        let snap = try await backend.snapshot()
        guard snap.instance == key.instance else { throw CoordinatorError.instanceChanged }
        guard let target = snap.sessions.first(where: { $0.key == key }) else {
            throw CoordinatorError.targetGone
        }
        let sameName = snap.sessions.filter { $0.displayName == target.displayName }
        guard sameName.count == 1 else { throw CoordinatorError.ambiguousDisplayName }

        try await backend.renameViaCLI(oldDisplayName: target.displayName, newDisplayName: newName)
    }

    // MARK: - 打开已有会话

    /// 打开已有会话：先验证 key 存活，再开新终端接入准确的 session ID。
    /// 已有存活本地窗口时应先激活（窗口绑定由上层维护，这里只处理新开）。
    public func openExisting(_ key: SessionKey, profileName: String?) async throws -> Int {
        let snap = try await backend.snapshot()
        guard snap.instance == key.instance else { throw CoordinatorError.instanceChanged }
        guard let target = snap.sessions.first(where: { $0.key == key }) else {
            throw CoordinatorError.targetGone
        }

        // 已有本应用登记的窗口：核对 iTerm2 标识仍存在再激活，避免重复开窗。
        if let wid = windowBindings[Self.bindingKey(key)] {
            if try await launcher.activateWindow(id: wid) {
                return wid
            }
            windowBindings.removeValue(forKey: Self.bindingKey(key)) // 窗口已关闭，清理绑定
        }
        _ = target

        let req = OperationRequest(action: .attach, sessionID: key.sessionID)
        try operations.writeRequest(req)
        let launch = try await launcher.openTerminal(operationID: req.id, profileName: profileName)

        // 关联 attach 的 TTY 后登记绑定，供下次定位。
        let deadline = Date().addingTimeInterval(associationTimeout)
        while Date() < deadline {
            if operations.readReport(req.id) != nil {
                try? operations.remove(req.id)
                break
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        windowBindings[Self.bindingKey(key)] = launch.windowID
        return launch.windowID
    }

    /// 本应用已登记窗口的会话 key，供自动镜像排除本地操作。
    public func localKeys() -> Set<String> { Set(windowBindings.keys) }

    static func bindingKey(_ k: SessionKey) -> String {
        "\(k.instance.serverPID):\(k.instance.startTime):\(k.sessionID):\(k.sessionCreated)"
    }
}
