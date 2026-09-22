import SwiftUI
import UUTmuxCore
import ServiceManagement

@main
struct UUTmuxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // 菜单栏入口。
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.menu)

        // 可调整大小的管理窗口。
        Window("UU 会话", id: "manager") {
            ManagerView(model: model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 760, height: 480)
    }
}

/// 应用级模型：持有 store、coordinator 与刷新循环。关闭窗口后菜单栏继续运行。
@MainActor
@Observable
final class AppModel {
    let store: SessionStore
    let coordinator: SessionCoordinator
    let mirror = MirrorCoordinator()
    let markers = LocalTerminalMarkers()
    /// 一次性操作提示（结果尚未确认、profile 回退、错误等）。
    var notice: String?
    /// 写操作进行中，防止重复提交。
    var isBusy = false
    /// 为外部新会话自动开窗，默认关闭。
    var autoMirror: Bool {
        didSet { UserDefaults.standard.set(autoMirror, forKey: "autoMirror") }
    }
    private let backend: TmuxBackend
    private var refreshTask: Task<Void, Never>?

    init() {
        self.autoMirror = UserDefaults.standard.bool(forKey: "autoMirror")
        let backend = TmuxBackend(config: .standard())
        self.backend = backend
        self.store = SessionStore(backend: backend)

        // helper 与 AppleScript 随应用分发；从 bundle 解析。
        let res = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let helper = res.appendingPathComponent("uu-terminal-helper")
        let script = res.appendingPathComponent("OpenTerminal.scpt")
        let launcher = ITermLauncher(scriptURL: script, helperURL: helper)
        self.coordinator = SessionCoordinator(backend: backend, launcher: launcher,
                                              operations: OperationStore())
        start()
    }

    /// 窗口可见或自动镜像开启时 2 秒刷新；否则 10 秒。首版只用 2 秒基线。
    /// ponytail: 隐藏窗口降频等自动镜像里程碑再接，先保证列表实时。
    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.store.refresh()
                await self.mirrorStep()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// 增量比较成功快照；自动镜像开启时为外部新会话开窗，本地操作与已镜像排除。
    private func mirrorStep() async {
        guard !isBusy, store.writeOperationsEnabled, let instance = store.instance else { return }
        isBusy = true
        defer { isBusy = false }
        let snapshot = SessionSnapshot(instance: instance, observedAt: Date(), sessions: store.sessions)
        // 本地操作 key：本 App 登记的窗口绑定 + uu-new/uut 报告的 TTY 命中。
        var local = await coordinator.localKeys()
        local.formUnion(markers.localSessionKeys(in: snapshot))
        let candidates = await mirror.candidates(from: snapshot, enabled: autoMirror,
                                                 localOperationKeys: local)
        guard !candidates.isEmpty else { return }
        for c in candidates {
            guard autoMirror else { break }
            do {
                _ = try await coordinator.openExisting(c.key, profileName: nil)
                await mirror.markMirrored(c.key)
            } catch {
                await mirror.markFailed(c.key)
                notice = "自动开窗失败（\(c.displayName)）：\(error)"
            }
        }
    }

    func refreshNow() { Task { await store.refresh() } }
    /// 登录启动（SMAppService.mainApp），默认关闭。
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                notice = "登录启动设置失败：\(error)"
            }
        }
    }


    func createSession(name: String?) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let trimmed = name?.trimmingCharacters(in: .whitespaces)
                let outcome = try await coordinator.create(
                    name: (trimmed?.isEmpty == false) ? trimmed : nil,
                    shell: nil, profileName: nil)
                notice = outcome.fellBackToDefaultProfile
                    ? "已用默认 profile 创建“\(outcome.displayName)”"
                    : "已创建“\(outcome.displayName)”"
                await store.refresh()
            } catch CoordinatorError.notConfirmed {
                notice = "结果尚未确认，可稍后刷新查看"
            } catch {
                notice = "创建失败：\(error)"
            }
        }
    }

    func openSession(_ key: SessionKey) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do { _ = try await coordinator.openExisting(key, profileName: nil) }
            catch { notice = "打开失败：\(error)" }
        }
    }

    func terminateSession(_ key: SessionKey) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await coordinator.terminate(key); await store.refresh() }
            catch { notice = "结束失败：\(error)" }
        }
    }

    func renameSession(_ key: SessionKey, to name: String) {
        guard !isBusy, store.writeOperationsEnabled else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await coordinator.rename(key, to: name)
                await store.refresh()
                notice = "已重命名为“\(name)”"
            } catch CoordinatorError.ambiguousDisplayName {
                notice = "重命名失败：存在同名会话，无法安全定位目标"
            } catch NameValidationError.containsControlCharacter {
                notice = "重命名失败：名称不能包含换行或控制字符"
            } catch {
                notice = "重命名失败：\(error)"
            }
        }
    }
}
