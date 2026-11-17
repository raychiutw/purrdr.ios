import Foundation
import PurrdrCore

/// 把 snapshot 投影成列表的 section(行為規格 F2.2–F2.4)。純函式：同樣的輸入永遠得到同樣的列表。
///
/// 多主機(#39):每台主機一個來源，合併成同一份 section;來源的順序就是主機順序(選取中主機在前)。
/// 之後的擴充點:Spaces 檢視(#40)是另一種投影。已釘選群組、未讀(#41)的規則在 `ChatUnread.swift`。
enum AgentListProjection {
    /// 一台主機的資料。
    struct Source {
        var host: HostSelection
        /// 非選取中主機的名稱與圖示;選取中主機為 `nil`(列上不標示)。
        var label: HostLabel?
        /// 主機名稱與圖示(Spaces 檢視的主機組標題;不分選取中與否)。
        var name = ""
        var icon = HostIcon.default
        var snapshot: HostSnapshot?
        /// 以 pane id 為鍵(同一台主機內唯一)。
        var previews: [String: MessagePreview]
        /// 這台主機的釘選、靜音與開啟紀錄(以 session 為鍵)。
        var preferences = ChatPreferences()
    }

    static func sections(
        snapshot: HostSnapshot?, query: String, previews: [String: MessagePreview], host: HostSelection = .demo
    ) -> [AgentSection] {
        sections(sources: [Source(host: host, label: nil, snapshot: snapshot, previews: previews)], query: query)
    }

    /// - Parameter visible: 目前開著的聊天(所有視窗;不算未讀)。
    static func sections(sources: [Source], query: String, visible: Set<ChatRoute> = []) -> [AgentSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = sources.enumerated().flatMap { hostOrder, source in
            entries(of: source, hostOrder: hostOrder, needle: needle, visible: visible)
        }
        return grouped(entries, order: \.order).map { AgentSection(group: $0, rows: $1.map(\.row)) }
    }

    /// 依 `Entry.group` 分組(`AgentGroup` 的順序)、組內依該組的規則排序;空的組不出現。Agents 與 Spaces 檢視共用。
    static func grouped<Item>(_ items: [Item], order: (Item) -> Entry) -> [(AgentGroup, [Item])] {
        let groups = Dictionary(grouping: items) { order($0).group }
        return AgentGroup.allCases.compactMap { group in
            guard let items = groups[group], !items.isEmpty else { return nil }
            return (group, items.sorted { group.areInIncreasingOrder(order($0), order($1)) })
        }
    }

    private struct RowEntry {
        var row: AgentRow
        var order: Entry
    }

    private static func entries(of source: Source, hostOrder: Int, needle: String, visible: Set<ChatRoute>) -> [RowEntry] {
        guard let snapshot = source.snapshot else { return [] }
        let order = Dictionary(snapshot.workspaces.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        let byWorkspace = Dictionary(grouping: snapshot.agents, by: \.workspaceID)
        return snapshot.agents.enumerated().compactMap { position, agent -> RowEntry? in
            let siblings = byWorkspace[agent.workspaceID] ?? [agent]
            let chat = ChatUnread.State(agent: agent, source: source, visible: visible)
            let row = AgentRow(
                agent: agent, siblings: siblings, preview: source.previews[agent.paneID], host: source.host, label: source.label, chat: chat)
            guard needle.isEmpty || matches(needle, agent: agent, row: row) else { return nil }
            return RowEntry(row: row, order: Entry(
                status: row.status, hostOrder: hostOrder, workspaceOrder: order[agent.workspaceID] ?? .max, position: position,
                lastMessage: source.previews[agent.paneID]?.date, pinnedAt: chat.pinnedAt))
        }
    }

    /// 分組與排序鍵(Agents 檢視的列、Spaces 檢視的列與卡片共用)。
    struct Entry {
        /// 顯示的狀態(決定「需要你／工作中／閒置」)。
        var status: AgentStatus
        var hostOrder: Int
        var workspaceOrder: Int
        var position: Int
        var lastMessage: Date?
        /// 釘選時間;有值就在「已釘選」,不看狀態(行為規格 F2.2)。
        var pinnedAt: Date?

        var group: AgentGroup { pinnedAt == nil ? status.group : .pinned }

        /// 主機順序(選取中主機在前)→ workspace 順序 → snapshot 內的位置。
        var order: (Int, Int, Int) { (hostOrder, workspaceOrder, position) }

        /// Spaces 主機組內：需要你 > 工作中 > 其他(完成與閒置同一級),再依 workspace 順序與位置。
        var urgencyOrder: (Int, Int, Int) {
            (min(status.urgencyRank, AgentStatus.done.urgencyRank), workspaceOrder, position)
        }
    }

    /// 不分大小寫的子字串比對：標題、herdr 名稱、session 與終端機標題、agent 種類與顯示名、資料夾、workspace 名稱與 id。
    /// 種類與顯示名都比對，搜「Antigravity」要找得到 herdr 叫 `agy` 的(行為規格 F2.3)。
    private static func matches(_ needle: String, agent: Agent, row: AgentRow) -> Bool {
        let fields: [String?] = [
            row.title, row.hostLabel?.name, agent.name, agent.sessionTitle, agent.terminalTitle, agent.kind, AgentKind.displayName(agent.kind),
            agent.cwd, agent.workspaceLabel, agent.workspaceID,
        ]
        return contains(needle, in: fields)
    }

    /// 搜尋比對：任一欄位含 `needle`(不分大小寫與變音符號)。Agents 與 Spaces 檢視共用(行為規格 F2.3)。
    static func contains(_ needle: String, in fields: [String?]) -> Bool {
        fields.contains { $0?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

extension AgentGroup {
    /// 「需要你」與「工作中」依主機順序(選取中主機在前，再依 workspace `number`);
    /// 閒置依最後訊息時間新→舊(跨主機比時間),無時間者最後、再依主機順序。已釘選依釘選時間舊→新(跨主機)。
    func areInIncreasingOrder(_ lhs: AgentListProjection.Entry, _ rhs: AgentListProjection.Entry) -> Bool {
        if self == .pinned, let left = lhs.pinnedAt, let right = rhs.pinnedAt, left != right {
            return left < right
        }
        if self == .idle, lhs.lastMessage != rhs.lastMessage {
            guard let left = lhs.lastMessage else { return false }
            guard let right = rhs.lastMessage else { return true }
            return left > right
        }
        return lhs.order < rhs.order
    }
}

extension Agent {
    /// 列表上的狀態：非 working 但 herdr 看到選單在等按鍵(`input_pending`)→ 當成 `blocked`(行為規格 F2.2)。
    var effectiveStatus: AgentStatus {
        status != .working && inputPending ? .blocked : status
    }
}

extension AgentStatus {
    /// 急迫度：需要你 > 工作中 > 完成 > 閒置(未知算閒置)。列表排序、狀態條與圖例共用。
    static let urgencyOrder: [AgentStatus] = [.blocked, .working, .done, .idle]

    /// 依急迫度歸類的狀態：未知算閒置。
    var urgencyStatus: AgentStatus { self == .unknown ? .idle : self }

    /// 在 `urgencyOrder` 的位置(越小越急迫)。
    var urgencyRank: Int { Self.urgencyOrder.firstIndex(of: urgencyStatus) ?? Self.urgencyOrder.count }

    /// 「需要你」只有 `blocked`;`done`、`idle`、`unknown` 都算閒置。
    var group: AgentGroup {
        switch self {
        case .blocked: .needsYou
        case .working: .working
        case .done, .idle, .unknown: .idle
        }
    }
}

extension AgentRow {
    init(
        agent: Agent, siblings: [Agent], preview: MessagePreview?, host: HostSelection, label: HostLabel?,
        chat: ChatUnread.State = ChatUnread.State()
    ) {
        let status = chat.displayStatus(agent.effectiveStatus)
        let title = AgentRowText.title(for: agent, siblings: siblings)
        let rowPreview: Preview = if status == .blocked {
            .needsInput
        } else if let preview {
            .message(preview.text, fromYou: preview.isFromUser)
        } else {
            .none
        }
        let time: Time? = status == .working ? .now : preview?.date.map(Time.date)
        var subtitle = AgentRowText.subtitle(for: agent, title: title, siblings: siblings)
        // 非選取中主機：副標以主機名開頭(#37 故事 2)。
        if let label { subtitle = label.name + " · " + subtitle }
        self.init(
            host: host, paneID: agent.paneID, kind: agent.kind, title: title, subtitle: subtitle, hostLabel: label,
            preview: rowPreview, time: time, status: status, isUnread: chat.isUnread, isPinned: chat.pinnedAt != nil, isMuted: chat.isMuted
        )
    }
}
