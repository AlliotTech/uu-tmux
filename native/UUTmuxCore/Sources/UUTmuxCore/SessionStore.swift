import Foundation
import Observation

/// 服务可达性 / 刷新状态，供 UI 决定是否禁用写操作、是否显示“暂时无法刷新”。
public enum BackendStatus: Sendable, Equatable {
    case unknown                 // 尚未第一次刷新
    case ok(sessionCount: Int)   // 查询成功
    case socketMissing           // UU 在但无 socket：仍可“新建”第一份会话
    case cliMissing              // UU 未安装
    case stale(reason: String)   // 曾成功过，本轮失败：保留上次列表，禁用写操作
}

/// `@MainActor` 状态模型：向 UI 提供快照与状态。
/// 查询失败不清空已有列表——只有查询成功且为空才显示空列表。
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var status: BackendStatus = .unknown
    public private(set) var lastSuccessfulRefresh: Date?
    public private(set) var isRefreshing = false
    /// 当前服务实例；变化说明服务重启，缓存身份失效。
    public private(set) var instance: BackendInstanceID?

    /// 搜索词。搜索只影响展示，不改变操作对象。
    public var searchText: String = ""

    private let backend: SnapshotProviding
    public init(backend: SnapshotProviding) {
        self.backend = backend
    }

    public var filteredSessions: [SessionInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in
            s.displayName.lowercased().contains(q)
            || s.tmuxSessionName.lowercased().contains(q)
            || (s.activePane?.currentPath.lowercased().contains(q) ?? false)
        }
    }

    /// 刷新一次。同一轮未结束不叠加（调用方负责不重入，这里加一道守卫）。
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snap = try await backend.snapshot()
            // 默认按创建时间排序；刷新维持稳定顺序。
            sessions = snap.sessions.sorted { $0.key.sessionCreated < $1.key.sessionCreated }
            instance = snap.instance
            status = .ok(sessionCount: sessions.count)
            lastSuccessfulRefresh = snap.observedAt
        } catch let error as BackendError {
            apply(error)
        } catch {
            status = .stale(reason: String(describing: error))
        }
    }

    private func apply(_ error: BackendError) {
        switch error {
        case .cliMissing:
            status = .cliMissing
        case .socketMissing:
            // UU 已安装但尚无 socket：保留可“新建”的语义，不误报“没有会话”。
            status = .socketMissing
        case .instanceChanged:
            // 服务在查询中途重启：本轮丢弃，缓存身份失效，等下一轮。
            instance = nil
            status = .stale(reason: "服务实例已变化")
        case .timedOut:
            status = .stale(reason: "查询超时")
        case .commandFailed(let msg):
            status = .stale(reason: msg)
        }
        // stale/socketMissing 时保留上次 sessions，不清空成空列表。
    }

    /// 写操作是否可用：只有成功快照后才放行依赖当前状态的写操作。
    public var writeOperationsEnabled: Bool {
        if case .ok = status { return true }
        return false
    }
}
