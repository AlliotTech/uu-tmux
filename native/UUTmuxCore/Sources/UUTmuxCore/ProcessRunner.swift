import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut
    case launchFailed(String)
}

/// 用可执行文件 URL + 参数数组启动短命令。用户名称、路径、ID 从不拼进 shell 源码。
/// 同时消费 stdout/stderr，限制输出大小，超时只终止自己启动的进程。
public struct ProcessRunner: Sendable {
    /// 输出上限，防止异常命令撑爆内存。
    public var maxOutputBytes: Int
    /// UU 命令统一使用 UTF-8 locale。
    public var environment: [String: String]

    public init(maxOutputBytes: Int = 8 * 1024 * 1024,
                environment: [String: String] = ProcessRunner.utf8Environment()) {
        self.maxOutputBytes = maxOutputBytes
        self.environment = environment
    }

    public static func utf8Environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    /// 运行并等待。timeout 秒后终止进程并抛出 `.timedOut`。
    public func run(executableURL: URL,
                    arguments: [String],
                    timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let limit = maxOutputBytes
        // 后台并发读到 EOF，避免子进程写满管道缓冲区而阻塞。EOF 只在进程退出后到达。
        let outTask = Self.drain(outPipe.fileHandleForReading, limit: limit)
        let errTask = Self.drain(errPipe.fileHandleForReading, limit: limit)

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }

        // 用异步轮询等待退出；waitUntilExit 的 RunLoop 等待可能在子进程已退出后仍不返回。
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if !timedOut, Date() >= deadline {
                process.terminate()
                timedOut = true
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        let out = await outTask.value
        let err = await errTask.value

        if timedOut { throw ProcessRunnerError.timedOut }
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    private static func drain(_ handle: FileHandle, limit: Int) -> Task<Data, Never> {
        Task.detached {
            var data = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if data.count > limit { data = data.prefix(limit); break }
            }
            return data
        }
    }
}
