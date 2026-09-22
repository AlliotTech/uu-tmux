import XCTest
@testable import UUTmuxCore

final class NameValidationTests: XCTestCase {
    func testRejectsControlCharacters() {
        for bad in ["a\nb", "a\tb", "x\u{0}y", "z\u{7F}"] {
            XCTAssertThrowsError(try validateSessionName(bad), "should reject \(bad.debugDescription)")
        }
    }
    func testRejectsEmpty() {
        XCTAssertThrowsError(try validateSessionName(""))
    }
    func testAcceptsUnicodeAndSpaces() throws {
        XCTAssertEqual(try validateSessionName("我的 开发终端"), "我的 开发终端")
        XCTAssertEqual(try validateSessionName("-leading-dash"), "-leading-dash")
    }
}

final class BackendWriteArgTests: XCTestCase {
    private func backend() -> TmuxBackend {
        TmuxBackend(config: BackendConfiguration(
            cliURL: URL(fileURLWithPath: "/x/cli"),
            muxURL: URL(fileURLWithPath: "/x/mux"),
            socketURL: URL(fileURLWithPath: "/x/sock")))
    }

    func testCreateArgsUseDashDashBoundaryForLeadingDashName() throws {
        let args = try backend().createArguments(name: "-danger", shell: nil)
        // `--` 必须在名称之前，防止被当成 CLI 选项。
        XCTAssertEqual(args, ["lterm", "new", "--", "-danger"])
    }
    func testCreateArgsWithShellAndName() throws {
        let args = try backend().createArguments(name: "dev", shell: "bash")
        XCTAssertEqual(args, ["lterm", "new", "--shell", "bash", "--", "dev"])
    }
    func testCreateArgsNoName() throws {
        XCTAssertEqual(try backend().createArguments(name: nil, shell: nil), ["lterm", "new"])
    }
    func testCreateArgsRejectsControlCharName() {
        XCTAssertThrowsError(try backend().createArguments(name: "a\nb", shell: nil))
    }
    func testAttachArgsTargetSessionID() {
        let args = backend().attachArguments(sessionID: "$5")
        XCTAssertEqual(args, ["-S", "/x/sock", "attach-session", "-t", "$5"])
    }
}

final class ITermLauncherParseTests: XCTestCase {
    private func launcher() -> ITermLauncher {
        ITermLauncher(scriptURL: URL(fileURLWithPath: "/x/s.applescript"),
                      helperURL: URL(fileURLWithPath: "/x/helper"))
    }
    func testParsePlainWindowID() throws {
        let r = try launcher().parse("21028\n")
        XCTAssertEqual(r.windowID, 21028)
        XCTAssertFalse(r.fellBackToDefault)
    }
    func testParseFallbackMarker() throws {
        let r = try launcher().parse("FALLBACK_DEFAULT:21040")
        XCTAssertEqual(r.windowID, 21040)
        XCTAssertTrue(r.fellBackToDefault)
    }
    func testParseGarbageThrows() {
        XCTAssertThrowsError(try launcher().parse("not-a-number"))
    }
}

final class OperationStoreTests: XCTestCase {
    private func tempStore() -> OperationStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uut-op-\(UUID().uuidString)")
        return OperationStore(root: dir)
    }

    func testRequestRoundTripPreservesUnicodeName() throws {
        let s = tempStore()
        let req = OperationRequest(action: .create, name: "我的 终端", shell: "zsh")
        try s.writeRequest(req)
        XCTAssertEqual(try s.readRequest(req.id).name, "我的 终端")
        XCTAssertEqual(try s.readRequest(req.id).action, .create)
    }

    func testPendingAndReportAndRemove() throws {
        let s = tempStore()
        let req = OperationRequest(action: .attach, sessionID: "$9")
        try s.writeRequest(req)
        XCTAssertEqual(s.pendingOperationIDs(), [req.id])
        XCTAssertNil(s.readReport(req.id))

        try s.writeReport(OperationReport(id: req.id, helperPID: 4242, tty: "/dev/ttys009"))
        XCTAssertEqual(s.readReport(req.id)?.tty, "/dev/ttys009")
        XCTAssertEqual(s.readReport(req.id)?.helperPID, 4242)

        try s.remove(req.id)
        XCTAssertTrue(s.pendingOperationIDs().isEmpty)
    }

    func testDirectoryOnlyAcceptsUUIDNames() throws {
        let s = tempStore()
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        // 非 UUID 目录不计入 pending。
        try FileManager.default.createDirectory(
            at: s.root.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
        XCTAssertTrue(s.pendingOperationIDs().isEmpty)
    }
}
