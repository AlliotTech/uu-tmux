import Foundation

public enum NameValidationError: Error, Equatable {
    case containsControlCharacter
    case empty
}

/// 名称校验：拒绝 NUL / 换行 / 其他控制字符。以 `-` 开头由命令构造时用 `--` 边界处理。
public func validateSessionName(_ name: String) throws -> String {
    let trimmed = name
    guard !trimmed.isEmpty else { throw NameValidationError.empty }
    for scalar in trimmed.unicodeScalars {
        // 控制字符：C0 (0x00–0x1F)、DEL (0x7F)、C1 (0x80–0x9F)。
        if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
            throw NameValidationError.containsControlCharacter
        }
    }
    return trimmed
}

extension TmuxBackend {
    /// 按 session_id 结束会话。先重查目标存在性由调用方（Coordinator）负责。
    /// 使用 `kill-session -t <session_id>`，禁止 `kill-server`。
    public func killSession(sessionID: String) async throws {
        _ = try await runMux(["kill-session", "-t", sessionID])
    }

    /// 通过 UU CLI 重命名以同步双端名称；直接 rename-window 不会同步。
    /// 以显示名为目标，故调用方必须先确认目标显示名唯一，否则拒绝。
    public func renameViaCLI(oldDisplayName: String, newDisplayName: String) async throws {
        let newName = try validateSessionName(newDisplayName)
        _ = try await runCLI(["lterm", "rename", "--", oldDisplayName, newName])
    }

    /// 构造在真实 TTY 中运行的 CLI 创建参数。名称经校验，`--` 边界防止被当选项。
    public func createArguments(name: String?, shell: String?) throws -> [String] {
        var args = ["lterm", "new"]
        if let shell { args += ["--shell", shell] }
        if let name {
            let valid = try validateSessionName(name)
            args += ["--", valid]
        }
        return args
    }

    /// 构造手动接入参数：普通客户端，参与尺寸协商（不加自动镜像的 ignore-size）。
    public func attachArguments(sessionID: String) -> [String] {
        config.muxSocketArguments + ["attach-session", "-t", sessionID]
    }

    // MARK: - 命令执行（写操作串行由 Coordinator 保证）

    func runMux(_ args: [String]) async throws -> String {
        try await runChecked(url: config.muxURL, args: config.muxSocketArguments + args)
    }
    func runCLI(_ args: [String]) async throws -> String {
        try await runChecked(url: config.cliURL, args: args)
    }
    private func runChecked(url: URL, args: [String]) async throws -> String {
        let result: ProcessResult
        do {
            result = try await runner.run(executableURL: url, arguments: args, timeout: queryTimeout)
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
}
