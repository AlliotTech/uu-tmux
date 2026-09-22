import Foundation

/// 服务实例身份：socket 规范路径 + tmux server PID + start_time。用于识别服务重启。
public struct BackendInstanceID: Sendable, Hashable {
    public let socketPath: String
    public let serverPID: Int
    public let startTime: Int

    public init(socketPath: String, serverPID: Int, startTime: Int) {
        self.socketPath = socketPath
        self.serverPID = serverPID
        self.startTime = startTime
    }
}

/// 会话主键：服务实例 + session_id + session_created。显示名不参与。
public struct SessionKey: Sendable, Hashable {
    public let instance: BackendInstanceID
    public let sessionID: String       // 形如 "$10"
    public let sessionCreated: Int

    public init(instance: BackendInstanceID, sessionID: String, sessionCreated: Int) {
        self.instance = instance
        self.sessionID = sessionID
        self.sessionCreated = sessionCreated
    }
}

/// 活动窗格观察值。
public struct PaneInfo: Sendable, Hashable {
    public let paneID: String          // "%2"
    public let command: String         // 前台程序名，如 "omp"
    public let currentPath: String     // 工作目录，保留完整值
    public let tty: String

    public init(paneID: String, command: String, currentPath: String, tty: String) {
        self.paneID = paneID
        self.command = command
        self.currentPath = currentPath
        self.tty = tty
    }
}

/// 客户端连接观察值。
public struct ClientInfo: Sendable, Hashable {
    public let sessionID: String
    public let tty: String
    public let pid: Int
    public let flags: String

    public init(sessionID: String, tty: String, pid: Int, flags: String) {
        self.sessionID = sessionID
        self.tty = tty
        self.pid = pid
        self.flags = flags
    }
}

/// 一份会话的完整观察结果。
public struct SessionInfo: Sendable, Identifiable, Hashable {
    public let key: SessionKey
    public let tmuxSessionName: String   // "uuremote-..."，诊断用
    public var displayName: String       // UU 展示名，允许重名，非主键
    public let primaryWindowID: String   // "@10"，按窗口索引排序后的第一个
    public let attachedClientCount: Int  // session_attached
    public let windowCount: Int
    public var activePane: PaneInfo?
    public var clients: [ClientInfo]

    public var id: String { "\(key.instance.serverPID):\(key.sessionID):\(key.sessionCreated)" }

    public init(key: SessionKey, tmuxSessionName: String, displayName: String,
                primaryWindowID: String, attachedClientCount: Int, windowCount: Int,
                activePane: PaneInfo?, clients: [ClientInfo]) {
        self.key = key
        self.tmuxSessionName = tmuxSessionName
        self.displayName = displayName
        self.primaryWindowID = primaryWindowID
        self.attachedClientCount = attachedClientCount
        self.windowCount = windowCount
        self.activePane = activePane
        self.clients = clients
    }
}

/// 成功快照。查询失败不生成空快照，用 `.failure` 表达。
public struct SessionSnapshot: Sendable {
    public let instance: BackendInstanceID
    public let observedAt: Date
    public let sessions: [SessionInfo]

    public init(instance: BackendInstanceID, observedAt: Date, sessions: [SessionInfo]) {
        self.instance = instance
        self.observedAt = observedAt
        self.sessions = sessions
    }
}

public enum BackendError: Error, Equatable {
    case socketMissing          // socket 不存在，UU 可能未启动服务
    case cliMissing             // UU 未安装
    case commandFailed(String)  // 非零退出或无法解析
    case instanceChanged        // 前后服务实例不一致，本轮快照丢弃
    case timedOut
}
