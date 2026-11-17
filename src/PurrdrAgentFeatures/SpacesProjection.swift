import Foundation
import PurrdrCore

/// Agent 列表的兩種檢視(行為規格 F2.1、#37 故事 7–14)。
public enum AgentListMode: String, CaseIterable, Sendable {
    /// 每個 workspace 一項：單一 agent 的 workspace 是聊天列，其他是 workspace 卡片。
    case spaces
    /// 每個 Agent 平鋪一列，不顯示終端機列。
    case agents
}

/// 列表檢視的存放處(只在這支裝置，不分主機)。
@MainActor
public protocol AgentListModeStore: AnyObject {
    func load() -> AgentListMode?
    func save(_ mode: AgentListMode)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryAgentListModeStore: AgentListModeStore {
    private var mode: AgentListMode?

    public init(_ mode: AgentListMode? = nil) {
        self.mode = mode
    }

    public func load() -> AgentListMode? { mode }
    public func save(_ mode: AgentListMode) { self.mode = mode }
}

/// 存在 `UserDefaults`。未知或缺值一律回到 Spaces(由呼叫端處理 `nil`)。
@MainActor
public final class UserDefaultsAgentListModeStore: AgentListModeStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "agentListMode") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AgentListMode? { defaults.string(forKey: key).flatMap(AgentListMode.init(rawValue:)) }
    public func save(_ mode: AgentListMode) { defaults.set(mode.rawValue, forKey: key) }
}

/// Spaces 檢視的一個分組(與 Agents 檢視同樣依「需要你／工作中／閒置」)。
public struct SpacesSection: Identifiable, Equatable, Sendable {
    public var group: AgentGroup
    public var items: [SpacesItem]
    public var id: AgentGroup { group }
    /// Section 標題的數量：這組顯示的項目數(卡片或聊天列),不是 Agent 數。
    public var count: Int { items.count }

    public init(group: AgentGroup, items: [SpacesItem]) {
        self.group = group
        self.items = items
    }
}

/// Spaces 檢視的一項。
public enum SpacesItem: Identifiable, Equatable, Sendable {
    /// 只有一個 Agent、沒有其他 pane 的 workspace:直接是聊天列。
    case chat(AgentRow)
    /// 兩個以上 Agent,或有 Agent 以外 pane 的 workspace。
    case card(WorkspaceCard)

    public var id: String {
        switch self {
        case .chat(let row): row.id
        case .card(let card): card.id
        }
    }
}

/// Workspace 卡片(#37 故事 8–11、G2):統計行、工作中狀態、版面圖按鈕，下方內縮列出 Agent 與終端機列。
public struct WorkspaceCard: Identifiable, Equatable, Sendable {
    public var host: HostSelection
    public var workspaceID: String
    /// 非選取中主機的名稱與圖示;選取中主機為 `nil`。
    public var hostLabel: HostLabel?
    /// Workspace 名稱(沒有時是 workspace id)。
    public var label: String
    public var agentCount: Int
    public var workingCount: Int
    public var tabCount: Int
    public var paneCount: Int
    /// 所有 pane 的共同資料夾(最後兩段);沒有時為 `nil`。
    public var folder: String?
    /// 最急迫的狀態：需要你 > 工作中 > 閒置(行為規格 F2.2)。
    public var status: AgentStatus
    /// 依 tab 分組的列;只有一個 tab 時是一組、沒有標題。
    public var groups: [TabGroup]

    /// 統計行:「N agents, M working · N tabs · N panes · 資料夾」。
    public var summary: String {
        var parts: [String] = []
        if agentCount > 0 {
            let agents = agentCount == 1 ? String(localized: "1 agent") : String(localized: "\(agentCount) agents")
            parts.append(workingCount > 0 ? String(localized: "\(agents), \(workingCount) working") : agents)
        }
        parts.append(tabCount == 1 ? String(localized: "1 tab") : String(localized: "\(tabCount) tabs"))
        parts.append(paneCount == 1 ? String(localized: "1 pane") : String(localized: "\(paneCount) panes"))
        if let folder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    /// 主機身分 + workspace id(`w1` 在每台主機都有)。
    public var id: String { "\(host.storedValue)/\(workspaceID)" }

    public init(
        host: HostSelection, workspaceID: String, hostLabel: HostLabel?, label: String, agentCount: Int, workingCount: Int,
        tabCount: Int, paneCount: Int, folder: String?, status: AgentStatus, groups: [TabGroup]
    ) {
        self.host = host
        self.workspaceID = workspaceID
        self.hostLabel = hostLabel
        self.label = label
        self.agentCount = agentCount
        self.workingCount = workingCount
        self.tabCount = tabCount
        self.paneCount = paneCount
        self.folder = folder
        self.status = status
        self.groups = groups
    }

    /// 卡片上同一個 tab 的列。
    public struct TabGroup: Identifiable, Equatable, Sendable {
        /// Tab id。
        public var id: String
        /// Tab 名稱(沒有時「Tab N」);workspace 只有一個 tab 時為 `nil`(不分組)。
        public var title: String?
        public var rows: [Row]

        public init(id: String, title: String?, rows: [Row]) {
            self.id = id
            self.title = title
            self.rows = rows
        }
    }

    public enum Row: Identifiable, Equatable, Sendable {
        case agent(AgentRow)
        case terminal(TerminalRow)

        public var id: String {
            switch self {
            case .agent(let row): row.id
            case .terminal(let row): row.id
            }
        }
    }
}

/// Agent 以外的 pane(shell、build、`npm run dev`):點了開它的 Pane 終端機(#37 故事 14、G3)。
public struct TerminalRow: Identifiable, Equatable, Sendable {
    public var host: HostSelection
    public var paneID: String
    /// 程式名與資料夾，以「 · 」連接。
    public var subtitle: String
    /// 程式名(終端機畫面的標題)。
    public var program: String

    public var id: String { "\(host.storedValue)/\(paneID)" }
    public var route: ChatRoute { ChatRoute(host: host, paneID: paneID) }

    public init(host: HostSelection, paneID: String, subtitle: String, program: String) {
        self.host = host
        self.paneID = paneID
        self.subtitle = subtitle
        self.program = program
    }
}

extension AgentListProjection {
    /// Spaces 檢視：每個 workspace 一項，分組與排序跟 Agents 檢視相同(行為規格 F2.1–F2.3)。
    ///
    /// - 只有一個 Agent、沒有其他 pane → 聊天列(跟 Agents 檢視的列相同)。
    /// - 兩個以上 Agent,或有 Agent 以外的 pane(含只有 shell)→ workspace 卡片，放在最急迫的狀態那組。
    /// - 已釘選(#41):被釘選的聊天列、或有任一 Agent 被釘選的卡片，放在「已釘選」,依釘選時間舊→新
    ///   (卡片以最早釘選的 Agent 為準),不看狀態。卡片裡的列各自帶未讀與釘選記號。
    /// - Parameter visible: 目前開著的聊天(不算未讀)。
    package static func spacesSections(sources: [Source], query: String, visible: Set<ChatRoute> = []) -> [SpacesSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = sources.enumerated().flatMap { hostOrder, source in
            spacesEntries(of: source, hostOrder: hostOrder, needle: needle, visible: visible)
        }
        return grouped(entries, order: \.order).map { SpacesSection(group: $0, items: $1.map(\.item)) }
    }

    private struct SpacesEntry {
        var item: SpacesItem
        /// 分組(`group`:已釘選或狀態)與排序。
        var order: Entry
    }

    /// 一台主機的 snapshot 在 Spaces 檢視要用到的東西(每個 workspace 共用，只算一次)。
    private struct SpacesContext {
        var source: Source
        var snapshot: HostSnapshot
        var hostOrder: Int
        var needle: String
        var visible: Set<ChatRoute>
        /// Agents 檢視的列(以 pane id),搜尋與分組都沿用。
        var rows: [String: AgentRow]
        /// 命中搜尋的 Agent pane。
        var matched: Set<String>
        /// Agent 在 snapshot 裡的位置(排序用)。
        var positions: [String: Int]

        init(source: Source, snapshot: HostSnapshot, hostOrder: Int, needle: String, visible: Set<ChatRoute>) {
            self.source = source
            self.snapshot = snapshot
            self.hostOrder = hostOrder
            self.needle = needle
            self.visible = visible
            rows = Dictionary(
                AgentListProjection.sections(sources: [source], query: "", visible: visible).flatMap(\.rows).map { ($0.paneID, $0) },
                uniquingKeysWith: { first, _ in first })
            matched = Set(AgentListProjection.sections(sources: [source], query: needle, visible: visible).flatMap(\.rows).map(\.paneID))
            positions = Dictionary(snapshot.agents.enumerated().map { ($1.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// workspace 依 snapshot 的順序;只出現在 agents／panes 的 workspace 也算。
        var workspaceIDs: [String] {
            var ids = snapshot.workspaces.map(\.id)
            for id in snapshot.agents.map(\.workspaceID) + snapshot.panes.map(\.workspaceID) where !ids.contains(id) {
                ids.append(id)
            }
            return ids
        }
    }

    private static func spacesEntries(of source: Source, hostOrder: Int, needle: String, visible: Set<ChatRoute>) -> [SpacesEntry] {
        guard let snapshot = source.snapshot else { return [] }
        let context = SpacesContext(source: source, snapshot: snapshot, hostOrder: hostOrder, needle: needle, visible: visible)
        return context.workspaceIDs.compactMap { spacesEntry(workspaceID: $0, in: context) }
    }

    /// 一個 workspace:只有一個 Agent、沒有其他 pane 是聊天列，否則是卡片;搜尋沒命中時 `nil`。
    private static func spacesEntry(workspaceID: String, in context: SpacesContext) -> SpacesEntry? {
        let snapshot = context.snapshot
        let workspace = snapshot.workspaces.first { $0.id == workspaceID }
        let agents = snapshot.agents.filter { $0.workspaceID == workspaceID }
        let shells = snapshot.terminalPanes.filter { $0.workspaceID == workspaceID }
        let statuses = agents.map(\.effectiveStatus)
        // 卡片的狀態：最急迫的那個(決定分組與卡片上的狀態標籤)。
        let status: AgentStatus = statuses.contains(.blocked) ? .blocked : statuses.contains(.working) ? .working
            : statuses.first ?? .idle
        // 釘選時間：workspace 裡最早釘選的 Agent(單一 Agent 時就是它的)。
        var order = Entry(
            status: status, hostOrder: context.hostOrder, workspaceOrder: workspace?.number ?? .max,
            position: agents.compactMap { context.positions[$0.paneID] }.min() ?? .max,
            lastMessage: agents.compactMap { context.source.previews[$0.paneID]?.date }.max(),
            pinnedAt: agents.compactMap { ChatUnread.State(agent: $0, source: context.source, visible: context.visible).pinnedAt }.min())

        if agents.count == 1, shells.isEmpty, let agent = agents.first, let row = context.rows[agent.paneID] {
            guard context.matched.contains(agent.paneID) else { return nil }
            // 聊天列跟 Agents 檢視一樣依列的狀態分組(未讀折算後)。
            order.status = row.status
            return SpacesEntry(item: .chat(row), order: order)
        }
        guard !agents.isEmpty || !shells.isEmpty else { return nil }
        let label = workspace?.label ?? agents.first?.workspaceLabel ?? workspaceID
        return workspaceCard(
            workspaceID: workspaceID, label: label, agents: agents, shells: shells, status: status, in: context
        ).map { SpacesEntry(item: .card($0), order: order) }
    }

    /// workspace 卡片。搜尋：命中 workspace 本身(名稱、id、主機名)→ 全部列;否則只留命中的列，都沒命中就是 `nil`(行為規格 F2.3)。
    private static func workspaceCard(
        workspaceID: String, label: String, agents: [Agent], shells: [Pane], status: AgentStatus, in context: SpacesContext
    ) -> WorkspaceCard? {
        let source = context.source
        let snapshot = context.snapshot
        let terminals = shells.map { TerminalRow(pane: $0, host: source.host, hostLabel: source.label) }
        let workspaceHit = context.needle.isEmpty || contains(context.needle, in: [label, workspaceID, source.label?.name])
        let shownAgents = workspaceHit ? agents : agents.filter { context.matched.contains($0.paneID) }
        let shownTerminals = workspaceHit ? terminals : terminals.filter { contains(context.needle, in: [$0.subtitle]) }
        guard workspaceHit || !shownAgents.isEmpty || !shownTerminals.isEmpty else { return nil }

        return WorkspaceCard(
            host: source.host, workspaceID: workspaceID, hostLabel: source.label, label: label,
            agentCount: agents.count, workingCount: agents.filter { $0.effectiveStatus == .working }.count,
            tabCount: tabIDs(of: workspaceID, in: snapshot).count,
            paneCount: Set(snapshot.panes.filter { $0.workspaceID == workspaceID }.map(\.id) + agents.map(\.paneID)).count,
            folder: commonFolder(agents.compactMap(\.cwd) + shells.compactMap(\.cwd)),
            status: status,
            groups: tabGroups(
                workspaceID: workspaceID, snapshot: snapshot,
                agentRows: shownAgents.compactMap { agent in
                    context.rows[agent.paneID].map { (agent.tabID, WorkspaceCard.Row.agent($0)) }
                },
                terminalRows: shownTerminals.map { row in
                    (shells.first { $0.id == row.paneID }?.tabID, WorkspaceCard.Row.terminal(row))
                })
        )
    }

    /// 這個 workspace 的 tab:snapshot 的 tabs,再加上只出現在 pane 或版面的 tab。依 number 排序。
    private static func tabIDs(of workspaceID: String, in snapshot: HostSnapshot) -> [String] {
        var ids = snapshot.tabs.filter { $0.workspaceID == workspaceID }.sorted { $0.number < $1.number }.map(\.id)
        let extra = snapshot.panes.filter { $0.workspaceID == workspaceID }.map(\.tabID)
            + snapshot.agents.filter { $0.workspaceID == workspaceID }.compactMap(\.tabID)
            + (snapshot.layouts ?? []).filter { $0.workspaceID == workspaceID }.map(\.tabID)
        for id in extra where !ids.contains(id) { ids.append(id) }
        return ids
    }

    /// 依 tab 分組：每組 agent 列在前、終端機列在後;只有一個 tab 時不加標題。不知道 tab 的列放最後一組。
    private static func tabGroups(
        workspaceID: String, snapshot: HostSnapshot,
        agentRows: [(String?, WorkspaceCard.Row)], terminalRows: [(String?, WorkspaceCard.Row)]
    ) -> [WorkspaceCard.TabGroup] {
        let ids = tabIDs(of: workspaceID, in: snapshot)
        let tabs = Dictionary(snapshot.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let all = agentRows + terminalRows
        var groups = ids.enumerated().compactMap { index, id -> WorkspaceCard.TabGroup? in
            let rows = all.filter { $0.0 == id }.map(\.1)
            guard !rows.isEmpty else { return nil }
            let number = tabs[id]?.number ?? index + 1
            let title = ids.count > 1 ? (tabs[id]?.label ?? String(localized: "Tab \(number)")) : nil
            return WorkspaceCard.TabGroup(id: id, title: title, rows: rows)
        }
        let unknown = all.filter { $0.0.map { !ids.contains($0) } ?? true }.map(\.1)
        if !unknown.isEmpty {
            if groups.count == 1, ids.count <= 1 {
                groups[0].rows += unknown
            } else {
                groups.append(WorkspaceCard.TabGroup(id: "\(workspaceID):?", title: nil, rows: unknown))
            }
        }
        return groups
    }

    /// 共同資料夾的最後兩段(例如 `demo/Projects`;Windows 主機是 `demo\Projects`,#26)。
    private static func commonFolder(_ paths: [String]) -> String? {
        let split = paths.map { HostPathSyntax.components($0).map(String.init) }
        guard var common = split.first, let first = paths.first else { return nil }
        for components in split.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        // 磁碟機代號(`C:`)不算資料夾段。
        if common.first?.hasSuffix(":") == true { common.removeFirst() }
        let folder = common.suffix(2).joined(separator: HostPathSyntax.separator(of: first))
        return folder.isEmpty ? nil : folder
    }
}

extension TerminalRow {
    /// 副標：程式名(pane 名稱 > 終端機標題;都沒有時「Shell」)與資料夾最後兩段。
    package init(pane: Pane, host: HostSelection, hostLabel: HostLabel?) {
        let program = [pane.label, pane.terminalTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? String(localized: "Shell")
        var parts = [program]
        if let folder = pane.cwd.map({ HostPathSyntax.trailingComponents($0, count: 2) }), !folder.isEmpty {
            parts.append(folder)
        }
        if let hostLabel { parts.insert(hostLabel.name, at: 0) }
        self.init(host: host, paneID: pane.id, subtitle: parts.joined(separator: " · "), program: program)
    }
}
