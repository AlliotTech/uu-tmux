import Foundation

/// 对成功快照做增量比较，判断哪些外部新会话应自动开窗，避免重复。
/// 启动 / 开启自动镜像 / 服务重连时，第一份成功快照作基线，展示全部而不开窗。
public actor MirrorCoordinator {
    private var currentInstance: BackendInstanceID?
    /// 已见过的会话 key（基线 + 已处理），不再作为新候选。
    private var known: Set<String> = []
    /// 已成功镜像的会话 key，用户关闭窗口也不重复弹。
    private var mirrored: Set<String> = []
    /// 是否已建立基线。
    private var hasBaseline = false
    /// 上一轮是否处于开启状态，用于识别“关闭→开启”这一刻并重建基线。
    private var wasEnabled = false

    public init() {}

    /// 计算本轮应自动开窗的候选。
    /// - enabled: 自动镜像是否开启。关闭时不产候选、不推进状态；
    ///   从关闭切到开启的那一轮，以当前快照重建基线（既有会话不开窗）。
    /// - localOperationKeys: 属于已关联本地操作的会话 key，排除在候选外。
    public func candidates(from snapshot: SessionSnapshot,
                           enabled: Bool = true,
                           localOperationKeys: Set<String> = []) -> [SessionInfo] {
        // 需要重建基线：实例变化 / 首次 / 刚从关闭切到开启。只登记不开窗。
        // 基线只登记“已有客户端”的会话——UU 常驻的空会话(clients=0)不登记，
        // 否则手机随后接入这个既有 SessionKey 时会被 known 永久压制，永远不开窗。
        let instanceChanged = currentInstance != snapshot.instance
        if instanceChanged || !hasBaseline || (enabled && !wasEnabled) {
            currentInstance = snapshot.instance
            known = Set(snapshot.sessions.filter { $0.attachedClientCount > 0 }.map(Self.key))
            // mirrored 跨开关切换保留（已开过窗不再打扰）；仅实例变化——服务重启、key 失效——时清空。
            if instanceChanged { mirrored.removeAll() }
            hasBaseline = true
            wasEnabled = enabled
            return []
        }
        wasEnabled = enabled
        guard enabled else { return [] }  // 关闭时不产候选、不推进状态（开启瞬间会重建基线）

        var result: [SessionInfo] = []
        for s in snapshot.sessions {
            let k = Self.key(s)
            if known.contains(k) || mirrored.contains(k) { continue }
            // 新会话：至少一个客户端 且 不属于本地操作，才成为候选。
            guard s.attachedClientCount > 0, !localOperationKeys.contains(k) else {
                // 无客户端：不登记，待其接入客户端后成为候选；本地操作登记排除。
                if localOperationKeys.contains(k) { known.insert(k) }
                continue
            }
            result.append(s)
            known.insert(k)  // 已作候选，不重复
        }
        return result
    }

    /// 确认窗口创建并建立连接后记为已镜像。
    public func markMirrored(_ key: SessionKey) {
        mirrored.insert(Self.key(key))
    }

    /// 开窗失败：从 known 移除，下轮可重试。
    public func markFailed(_ key: SessionKey) {
        known.remove(Self.key(key))
    }

    static func key(_ s: SessionInfo) -> String { key(s.key) }
    static func key(_ k: SessionKey) -> String {
        "\(k.instance.serverPID):\(k.instance.startTime):\(k.sessionID):\(k.sessionCreated)"
    }
}
