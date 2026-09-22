import XCTest
@testable import UUTmuxCore

final class TmuxBackendTests: XCTestCase {
    let sep = "\t"
    var instance: BackendInstanceID { BackendInstanceID(socketPath: "/s", serverPID: 1, startTime: 2) }

    private func backend() -> TmuxBackend {
        TmuxBackend(config: BackendConfiguration(
            cliURL: URL(fileURLWithPath: "/x/cli"),
            muxURL: URL(fileURLWithPath: "/x/mux"),
            socketURL: URL(fileURLWithPath: "/x/sock")))
    }

    func testSessionParsePreservesUnicodeAndSpaces() throws {
        let b = backend()
        let line = ["$10", "1789962939", "3", "2", "uuremote-3100783369"].joined(separator: sep)
        let sessions = try b.parseSessions(line, instance: instance)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].key.sessionID, "$10")
        XCTAssertEqual(sessions[0].key.sessionCreated, 1789962939)
        XCTAssertEqual(sessions[0].attachedClientCount, 3)
        XCTAssertEqual(sessions[0].windowCount, 2)
        XCTAssertEqual(sessions[0].tmuxSessionName, "uuremote-3100783369")
    }

    func testWindowNameWithSpacesQuotesUnicodeSurvives() {
        let b = backend()
        let name = #"我的 "开发" 终端 with spaces"#
        let line = ["$2", "@2", "0", name].joined(separator: sep)
        let windows = b.parseWindows(line)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].name, name)
        XCTAssertEqual(windows[0].windowID, "@2")
        XCTAssertEqual(windows[0].index, 0)
    }

    func testPanePathWithSpacesSurvives() {
        let b = backend()
        let path = "/Users/alliot/My Projects/uu tmux"
        let line = ["$2", "1", "1", "%2", "/dev/ttys013", "omp", path].joined(separator: sep)
        let panes = b.parsePanes(line)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes[0].pane.currentPath, path)
        XCTAssertEqual(panes[0].pane.command, "omp")
        XCTAssertTrue(panes[0].paneActive)
        XCTAssertTrue(panes[0].windowActive)
    }

    func testDuplicateDisplayNamesRemainSeparateIdentities() throws {
        let b = backend()
        let s1 = ["$2", "100", "1", "1", "uuremote-a"].joined(separator: sep)
        let s2 = ["$3", "200", "1", "1", "uuremote-b"].joined(separator: sep)
        let sessions = try b.parseSessions(s1 + "\n" + s2, instance: instance)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertNotEqual(sessions[0].key, sessions[1].key)
        // 同名窗口不应合并会话身份。
        let w1 = ["$2", "@2", "0", "dev"].joined(separator: sep)
        let w2 = ["$3", "@3", "0", "dev"].joined(separator: sep)
        let windows = b.parseWindows(w1 + "\n" + w2)
        XCTAssertEqual(Set(windows.map(\.sessionID)).count, 2)
    }

    func testMalformedSessionLineThrows() {
        let b = backend()
        let bad = ["$2", "not-a-number", "1", "1", "name"].joined(separator: sep)
        XCTAssertThrowsError(try b.parseSessions(bad, instance: instance))
    }

    func testClientParse() {
        let b = backend()
        let line = ["$3", "/dev/ttys015", "78423", "attached,focused,UTF-8"].joined(separator: sep)
        let clients = b.parseClients(line)
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients[0].pid, 78423)
        XCTAssertEqual(clients[0].flags, "attached,focused,UTF-8")
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testRunCapturesStdoutAndExitCode() async throws {
        let r = ProcessRunner()
        let res = try await r.run(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                  arguments: ["hello world"], timeout: 5)
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertEqual(res.stdoutText.trimmingCharacters(in: .newlines), "hello world")
    }

    func testRepeatedConcurrentCommandsFinish() async {
        let finished = expectation(description: "短命令并发退出后刷新能继续")
        let worker = Task {
            do {
                let runner = ProcessRunner()
                for _ in 0..<100 {
                    async let first = runner.run(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                                 arguments: ["first"], timeout: 1)
                    async let second = runner.run(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                                  arguments: ["second"], timeout: 1)
                    let results = try await (first, second)
                    XCTAssertEqual(results.0.stdoutText, "first\n")
                    XCTAssertEqual(results.1.stdoutText, "second\n")
                    XCTAssertEqual(results.0.exitCode, 0)
                    XCTAssertEqual(results.1.exitCode, 0)
                }
            } catch {
                XCTFail("命令执行失败：\(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 15)
        worker.cancel()
    }

    func testNonZeroExit() async throws {
        let r = ProcessRunner()
        let res = try await r.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", "exit 3"], timeout: 5)
        XCTAssertEqual(res.exitCode, 3)
    }

    func testTimeoutTerminates() async {
        let r = ProcessRunner()
        do {
            _ = try await r.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                arguments: ["-c", "sleep 10"], timeout: 0.5)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut)
        }
    }

    func testArgumentsNotShellInterpreted() async throws {
        // 参数含 shell 元字符也不应被解释——直接作为 echo 的字面参数。
        let r = ProcessRunner()
        let res = try await r.run(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                  arguments: ["$(whoami); rm -rf /"], timeout: 5)
        XCTAssertEqual(res.stdoutText.trimmingCharacters(in: .newlines), "$(whoami); rm -rf /")
    }
}
