import Foundation

public enum LauncherError: Error, Equatable {
    case scriptMissing
    case automationFailed(String)
    case badWindowID(String)
}

public struct LaunchResult: Sendable, Equatable {
    public let windowID: Int
    /// 指定 profile 缺失、已回退默认时为 true，供 App 提示一次。
    public let fellBackToDefault: Bool
}

/// 通过 /usr/bin/osascript 运行随应用分发的固定 AppleScript，参数单独传递。
/// 自动化调用在异步执行器完成，不阻塞 UI。
public struct ITermLauncher: Sendable {
    public let scriptURL: URL
    public let helperURL: URL
    public let runner: ProcessRunner
    /// 自动化授权 + 窗口创建可能较慢，给足超时（与查询超时分开）。
    public var timeout: TimeInterval

    public init(scriptURL: URL, helperURL: URL,
                runner: ProcessRunner = ProcessRunner(), timeout: TimeInterval = 30) {
        self.scriptURL = scriptURL
        self.helperURL = helperURL
        self.runner = runner
        self.timeout = timeout
    }

    /// 打开终端运行 helper。返回新窗口 id。
    public func openTerminal(operationID: UUID, profileName: String?) async throws -> LaunchResult {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { throw LauncherError.scriptMissing }
        var args = [scriptURL.path, helperURL.path, operationID.uuidString]
        if let profileName, !profileName.isEmpty { args.append(profileName) }

        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: args, timeout: timeout)
        } catch {
            throw LauncherError.automationFailed(String(describing: error))
        }
        guard result.exitCode == 0 else {
            throw LauncherError.automationFailed(result.stderrText)
        }
        return try parse(result.stdoutText)
    }

    func parse(_ output: String) throws -> LaunchResult {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = line.range(of: "FALLBACK_DEFAULT:") {
            let idPart = String(line[range.upperBound...])
            guard let id = Int(idPart) else { throw LauncherError.badWindowID(line) }
            return LaunchResult(windowID: id, fellBackToDefault: true)
        }
        guard let id = Int(line) else { throw LauncherError.badWindowID(line) }
        return LaunchResult(windowID: id, fellBackToDefault: false)
    }

    /// 按 id 定位并激活已有 iTerm2 窗口。返回是否找到。
    public func activateWindow(id: Int) async throws -> Bool {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            if id of w is \(id) then
              select w
              activate
              return "1"
            end if
          end repeat
          return "0"
        end tell
        """
        let result = try? await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script], timeout: timeout)
        return result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
