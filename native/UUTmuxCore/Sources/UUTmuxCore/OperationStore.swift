import Foundation

/// 一次创建/接入请求。App 生成，写入 request.json；helper 回报写入 report.json。
public struct OperationRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case create, attach }

    public let id: UUID
    public let action: Action
    public let name: String?        // 用户可选名称（自由文本，只放 JSON，不进命令行）
    public let shell: String?
    public let sessionID: String?   // attach 时的目标 tmux session_id
    public let createdAt: Date

    public init(id: UUID = UUID(), action: Action, name: String? = nil,
                shell: String? = nil, sessionID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.action = action
        self.name = name
        self.shell = shell
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}

/// helper 在真实 TTY 中回报的关联信息。
public struct OperationReport: Codable, Sendable, Equatable {
    public let id: UUID
    public let helperPID: Int
    public let tty: String
    public let reportedAt: Date

    public init(id: UUID, helperPID: Int, tty: String, reportedAt: Date = Date()) {
        self.id = id
        self.helperPID = helperPID
        self.tty = tty
        self.reportedAt = reportedAt
    }
}

/// 操作记录持久化。目录只接受应用生成的 UUID，文件原子写入。
/// 应用重启后可枚举未完成请求，避免重复创建。
public struct OperationStore: Sendable {
    public let root: URL

    /// 默认 `~/Library/Application Support/uu-tmux/operations`。
    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("uu-tmux/operations", isDirectory: true)
        }
    }

    private func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func requestURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("request.json") }
    public func reportURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("report.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func writeRequest(_ req: OperationRequest) throws {
        try FileManager.default.createDirectory(at: dir(req.id), withIntermediateDirectories: true)
        try atomicWrite(try Self.encoder.encode(req), to: requestURL(req.id))
    }

    public func writeReport(_ report: OperationReport) throws {
        try FileManager.default.createDirectory(at: dir(report.id), withIntermediateDirectories: true)
        try atomicWrite(try Self.encoder.encode(report), to: reportURL(report.id))
    }

    public func readRequest(_ id: UUID) throws -> OperationRequest {
        try Self.decoder.decode(OperationRequest.self, from: Data(contentsOf: requestURL(id)))
    }

    public func readReport(_ id: UUID) -> OperationReport? {
        guard let data = try? Data(contentsOf: reportURL(id)) else { return nil }
        return try? Self.decoder.decode(OperationReport.self, from: data)
    }

    /// 枚举所有已写 request 的操作 UUID。
    public func pendingOperationIDs() -> [UUID] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: requestURL($0).path) }
    }

    public func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: dir(id))
    }

    /// 原子写入：写临时文件再 rename。
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
