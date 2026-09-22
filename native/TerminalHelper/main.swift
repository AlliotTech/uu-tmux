import Foundation
import UUTmuxCore

// TerminalHelper：在 iTerm2 提供的真实 TTY 中运行。
// 用法：uu-terminal-helper --request <UUID>
// 1. 校验 stdin/stdout 为 TTY；2. 回报自己的 PID/TTY/UUID；3. 用继承的终端 exec UU CLI。
// 不分配额外终端，不安装“关闭即杀会话”的 trap——关窗口只断开。

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("uu-terminal-helper: " + msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "--request", let opID = UUID(uuidString: args[2]) else {
    fail("用法: uu-terminal-helper --request <UUID>")
}

// stdin/stdout 必须是 TTY，否则关联无意义。
guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
    fail("标准输入输出不是 TTY")
}
guard let ttyName = String(cString: ttyname(STDIN_FILENO), encoding: .utf8) else {
    fail("无法读取 TTY 名")
}

let store = OperationStore()
let request: OperationRequest
do {
    request = try store.readRequest(opID)
} catch {
    fail("找不到操作请求 \(opID): \(error)")
}

// 回报关联信息，供 App 通过 list-clients 的 TTY 建立绑定。
let report = OperationReport(id: opID, helperPID: Int(getpid()), tty: ttyName)
do { try store.writeReport(report) } catch {
    fail("写 report 失败: \(error)")
}

let config = BackendConfiguration.standard()
let backend = TmuxBackend(config: config)

// 构造要 exec 的命令。create 走 CLI new；attach 走 mux attach-session。
let execURL: URL
let execArgs: [String]
switch request.action {
case .create:
    execURL = config.cliURL
    do {
        execArgs = try backend.createArguments(name: request.name, shell: request.shell)
    } catch {
        fail("名称非法: \(error)")
    }
case .attach:
    guard let sid = request.sessionID else { fail("attach 缺少 sessionID") }
    execURL = config.muxURL
    execArgs = backend.attachArguments(sessionID: sid)
}

// 用继承的终端 exec，本进程被替换——CLI/tmux client 的生命周期不依赖 App。
let cargs = [execURL.path] + execArgs
let cStrings: [UnsafeMutablePointer<CChar>?] = cargs.map { strdup($0) } + [nil]
execv(execURL.path, cStrings)
// execv 只在失败时返回。
fail("exec 失败: \(String(cString: strerror(errno)))")
