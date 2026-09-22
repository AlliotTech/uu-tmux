import SwiftUI
import UUTmuxCore

struct ManagerView: View {
    @Bindable var model: AppModel
    @State private var showNewSheet = false
    @State private var newName = ""
    @State private var terminateTarget: SessionInfo?
    @State private var renameTarget: SessionInfo?
    @State private var renameName = ""
    @State private var selection: SessionInfo.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let notice = model.notice {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("忽略")
                }
                .padding(8)
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showNewSheet) { newSessionSheet }
        .sheet(item: $renameTarget) { s in renameSheet(s) }
        .alert("结束会话", isPresented: Binding(
            get: { terminateTarget != nil },
            set: { if !$0 { terminateTarget = nil } })) {
            Button("取消", role: .cancel) { terminateTarget = nil }
            Button("结束", role: .destructive) {
                if let t = terminateTarget { model.terminateSession(t.key) }
                terminateTarget = nil
            }
            .disabled(model.isBusy || !model.store.writeOperationsEnabled)
        } message: {
            if let t = terminateTarget {
                Text("将结束“\(t.displayName)”\n程序：\(t.activePane?.command ?? "-")\n目录：\(t.activePane?.currentPath ?? "-")\n连接：\(t.attachedClientCount)")
            }
        }
    }

    private var newSessionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建会话").font(.headline)
            TextField("名称（可选）", text: $newName)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("取消") { showNewSheet = false; newName = "" }
                Button("创建") {
                    model.createSession(name: newName)
                    showNewSheet = false; newName = ""
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func renameSheet(_ s: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名会话").font(.headline)
            TextField("名称", text: $renameName)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("取消") { renameTarget = nil }
                Button("保存") {
                    model.renameSession(s.key, to: renameName)
                    renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || !model.store.writeOperationsEnabled
                          || renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    // 顶部：搜索 + 新建。
    private var header: some View {
        @Bindable var store = model.store
        return HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称或目录", text: $store.searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新")
            // socket 不存在但 UU 可用时仍允许新建首个会话；无法查询成功时其余写操作禁用。
            Button("新建") { showNewSheet = true }
                .disabled(model.isBusy || !canCreate)
        }
        .padding(8)
    }

    /// 新建放行：查询成功（有会话或空列表都行）或 UU 在但无 socket。
    private var canCreate: Bool {
        switch model.store.status {
        case .ok, .socketMissing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.store.filteredSessions
        if rows.isEmpty, case .ok = model.store.status {
            // 只有查询成功且为空才显示空列表。
            ContentUnavailableView("没有会话", systemImage: "terminal",
                                   description: Text("点击“新建”创建第一个会话"))
        } else if rows.isEmpty {
            ContentUnavailableView("暂无数据", systemImage: "hourglass",
                                   description: Text(statusDetail))
        } else {
            Table(rows, selection: $selection) {
                TableColumn("名称") { s in
                    Text(s.displayName).help(s.tmuxSessionName)
                }
                TableColumn("状态") { s in Text(stateText(s)) }
                TableColumn("程序") { s in Text(s.activePane?.command ?? "-") }
                TableColumn("工作目录") { s in
                    Text(s.activePane?.currentPath ?? "-")
                        .lineLimit(1).truncationMode(.middle)
                        .help(s.activePane?.currentPath ?? "")
                }
                TableColumn("操作") { s in
                    HStack(spacing: 8) {
                        Button { model.openSession(s.key) } label: {
                            Label("打开", systemImage: "arrow.up.right.square")
                        }
                        .help("在 iTerm2 中打开此会话")

                        Button(role: .destructive) { terminateTarget = s } label: {
                            Label("结束", systemImage: "stop.circle")
                        }
                        .tint(.red)
                        .help("结束此会话及其中的终端任务")
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .disabled(model.isBusy || !model.store.writeOperationsEnabled)
                }
                .width(70)
            }
            .contextMenu(forSelectionType: SessionInfo.ID.self) { ids in
                if let s = rows.first(where: { ids.contains($0.id) }) {
                    let disabled = model.isBusy || !model.store.writeOperationsEnabled
                    Button("打开") { model.openSession(s.key) }.disabled(disabled)
                    Button("重命名") { renameName = s.displayName; renameTarget = s }.disabled(disabled)
                    Button("结束", role: .destructive) { terminateTarget = s }.disabled(disabled)
                }
            }
        }
    }

    // 底部：连接状态 + 最后成功刷新时间。
    private var footer: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusDetail).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let t = model.store.lastSuccessfulRefresh {
                Text("最后刷新 " + t.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private func stateText(_ s: SessionInfo) -> String {
        s.attachedClientCount == 0 ? "后台" : "已连接 \(s.attachedClientCount)"
    }

    private var statusDetail: String {
        switch model.store.status {
        case .unknown: return "正在连接…"
        case .ok(let n): return "已连接 · \(n) 个会话"
        case .socketMissing: return "UU 无 socket · 可新建首个会话"
        case .cliMissing: return "未找到 UU"
        case .stale(let r): return "暂时无法刷新 · \(r)"
        }
    }

    private var statusColor: Color {
        switch model.store.status {
        case .ok: return .green
        case .unknown: return .gray
        case .socketMissing: return .yellow
        case .cliMissing, .stale: return .orange
        }
    }
}
