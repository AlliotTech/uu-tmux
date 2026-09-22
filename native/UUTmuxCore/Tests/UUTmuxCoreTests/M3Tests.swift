import XCTest
@testable import UUTmuxCore

private func inst(_ pid: Int = 1, _ start: Int = 100) -> BackendInstanceID {
    BackendInstanceID(socketPath: "/s", serverPID: pid, startTime: start)
}
private func session(_ id: String, created: Int, instance: BackendInstanceID,
                     clients: Int, name: String = "n") -> SessionInfo {
    let key = SessionKey(instance: instance, sessionID: id, sessionCreated: created)
    let cs = (0..<clients).map { ClientInfo(sessionID: id, tty: "/dev/tty\($0)", pid: 100 + $0, flags: "attached") }
    return SessionInfo(key: key, tmuxSessionName: name, displayName: name,
                       primaryWindowID: "@1", attachedClientCount: clients, windowCount: 1,
                       activePane: nil, clients: cs)
}

final class MirrorCoordinatorTests: XCTestCase {
    func testFirstSnapshotIsBaselineNoWindows() async {
        let m = MirrorCoordinator()
        let i = inst()
        let snap = SessionSnapshot(instance: i, observedAt: Date(),
            sessions: [session("$1", created: 1, instance: i, clients: 1)])
        let c = await m.candidates(from: snap)
        XCTAssertTrue(c.isEmpty, "第一份快照只作基线")
    }

    func testNewExternalSessionBecomesCandidate() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(),
            sessions: [session("$1", created: 1, instance: i, clients: 1)]))
        // 新出现的、有客户端连接的外部会话。
        let snap2 = SessionSnapshot(instance: i, observedAt: Date(), sessions: [
            session("$1", created: 1, instance: i, clients: 1),
            session("$2", created: 2, instance: i, clients: 1),
        ])
        let c = await m.candidates(from: snap2)
        XCTAssertEqual(c.map { $0.key.sessionID }, ["$2"])
    }

    func testNoClientSessionNotCandidate() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: []))
        let snap = SessionSnapshot(instance: i, observedAt: Date(),
            sessions: [session("$2", created: 2, instance: i, clients: 0)])
        let c = await m.candidates(from: snap)
        XCTAssertTrue(c.isEmpty, "无客户端不作候选")
    }

    func testLocalOperationExcluded() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: []))
        let s = session("$2", created: 2, instance: i, clients: 1)
        let localKey = "\(i.serverPID):\(i.startTime):$2:2"
        let c = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s]),
                                   localOperationKeys: [localKey])
        XCTAssertTrue(c.isEmpty, "本地操作不自动开窗")
    }

    func testMirroredNotReemittedAfterUserClosesWindow() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: []))
        let s = session("$2", created: 2, instance: i, clients: 1)
        let c1 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s]))
        XCTAssertEqual(c1.count, 1)
        await m.markMirrored(s.key)
        // 用户关闭窗口后（仍在快照中），不再重复弹。
        let c2 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s]))
        XCTAssertTrue(c2.isEmpty)
    }

    func testInstanceChangeResetsBaseline() async {
        let m = MirrorCoordinator()
        let i1 = inst(1, 100)
        _ = await m.candidates(from: SessionSnapshot(instance: i1, observedAt: Date(),
            sessions: [session("$1", created: 1, instance: i1, clients: 1)]))
        // 服务重启：新实例，第一份快照重新作基线，不开窗。
        let i2 = inst(2, 200)
        let c = await m.candidates(from: SessionSnapshot(instance: i2, observedAt: Date(),
            sessions: [session("$1", created: 1, instance: i2, clients: 1)]))
        XCTAssertTrue(c.isEmpty, "实例变化后第一份快照作基线")
    }

    func testFailedRetryReemitted() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: []))
        let s = session("$2", created: 2, instance: i, clients: 1)
        let c1 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s]))
        XCTAssertEqual(c1.count, 1)
        await m.markFailed(s.key)   // 开窗失败，可重试
        let c2 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s]))
        XCTAssertEqual(c2.count, 1, "失败会话下轮仍作候选")
    }

    // UU 常驻的空会话在基线时无客户端；手机随后接入同一 SessionKey 应自动开窗，
    // 不能因为它出现在基线里就被永久压制（这是自动镜像“不生效”的根因）。
    func testPreexistingEmptySessionMirroredWhenItAttaches() async {
        let m = MirrorCoordinator()
        let i = inst()
        let empty = session("$5", created: 5, instance: i, clients: 0)
        let base = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [empty]))
        XCTAssertTrue(base.isEmpty, "基线不开窗")
        let attached = session("$5", created: 5, instance: i, clients: 1)
        let c = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [attached]))
        XCTAssertEqual(c.map { $0.key.sessionID }, ["$5"], "既有空会话被接入后应镜像")
    }

    // 关闭时不产候选、不推进状态。
    func testDisabledEmitsNothing() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: []), enabled: false)
        let c = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(),
            sessions: [session("$2", created: 2, instance: i, clients: 1)]), enabled: false)
        XCTAssertTrue(c.isEmpty, "关闭时即便出现有客户端的新会话也不开窗")
    }

    // 开启时已连接的会话只登记为基线；之后新出现的会话才作候选。
    func testEnableRebaselinesPreexistingThenMirrorsNew() async {
        let m = MirrorCoordinator()
        let i = inst()
        let s1detached = session("$1", created: 1, instance: i, clients: 0)
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s1detached]), enabled: false)
        let s1attached = session("$1", created: 1, instance: i, clients: 1)
        let c1 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s1attached]), enabled: true)
        XCTAssertTrue(c1.isEmpty, "开启时已连接的会话不开窗")
        let s2 = session("$2", created: 2, instance: i, clients: 1)
        let c2 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [s1attached, s2]), enabled: true)
        XCTAssertEqual(c2.map { $0.key.sessionID }, ["$2"], "开启后新出现的会话才作候选")
    }

    // 已镜像的会话跨“关闭再开启”应保留，不因归零后重新接入而再次开窗；
    // mirrored 只在实例变化时清空。
    func testMirroredPreservedAcrossEnableToggle() async {
        let m = MirrorCoordinator()
        let i = inst()
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: []), enabled: true)
        let attached = session("$2", created: 2, instance: i, clients: 1)
        let c1 = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [attached]), enabled: true)
        XCTAssertEqual(c1.count, 1)
        await m.markMirrored(attached.key)
        let detached = session("$2", created: 2, instance: i, clients: 0)
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [detached]), enabled: false)
        _ = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [detached]), enabled: true)
        let c = await m.candidates(from: SessionSnapshot(instance: i, observedAt: Date(), sessions: [attached]), enabled: true)
        XCTAssertTrue(c.isEmpty, "已镜像的会话归零后重新接入不重复开窗")
    }
}
