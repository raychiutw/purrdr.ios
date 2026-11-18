import Foundation
import PurrdrCore

/// Agent 列表的兩種檢視(行為規格 F2.1、#37 故事 7–14)。
public enum AgentListMode: String, CaseIterable, Sendable {
    /// 每個 workspace 一項：依主機分組，單一 agent 的 workspace 是聊天列，其他是 workspace 群組。
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

/// Spaces 檢視的一個分組(#103):最上面「已釘選」(不分主機),其餘每台主機一組。
public struct SpacesSection: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case pinned
        case host(SpacesHost)
    }

    public var kind: Kind
    public var items: [SpacesItem]

    public var id: String {
        switch kind {
        case .pinned: "pinned"
        case .host(let header): header.host.storedValue
        }
    }

    /// 主機組的標題資料;已釘選組為 `nil`。
    public var host: SpacesHost? {
        if case .host(let header) = kind { header } else { nil }
    }

    public init(kind: Kind, items: [SpacesItem]) {
        self.kind = kind
        self.items = items
    }
}

/// 主機組的標題：主機身分、名稱、圖示與這台主機所有 Agent 依狀態的數量。
public struct SpacesHost: Equatable, Sendable {
    public var host: HostSelection
    public var name: String
    public var icon: HostIcon
    public var counts: SpacesStatusCounts

    public init(host: HostSelection, name: String, icon: HostIcon, counts: SpacesStatusCounts) {
        self.host = host
        self.name = name
        self.icon = icon
        self.counts = counts
    }
}

/// 狀態條的一段：狀態與相對長度。
public struct StatusSegment: Equatable, Sendable {
    public var status: AgentStatus
    public var weight: Int

    public init(status: AgentStatus, weight: Int) {
        self.status = status
        self.weight = weight
    }
}

/// 依狀態的 Agent 數量。完成只算未讀的;已讀的完成算閒置(#41)。
public struct SpacesStatusCounts: Equatable, Sendable {
    public var needsYou = 0
    public var working = 0
    public var done = 0
    public var idle = 0

    public init(needsYou: Int = 0, working: Int = 0, done: Int = 0, idle: Int = 0) {
        self.needsYou = needsYou
        self.working = working
        self.done = done
        self.idle = idle
    }

    /// 以列表上的狀態(已折算未讀)計數。
    init(statuses: [AgentStatus]) {
        for status in statuses {
            switch status.urgencyStatus {
            case .blocked: needsYou += 1
            case .working: working += 1
            case .done: done += 1
            case .idle, .unknown: idle += 1
            }
        }
    }

    /// 某個狀態的數量(未知算閒置)。
    package func count(of status: AgentStatus) -> Int {
        switch status.urgencyStatus {
        case .blocked: needsYou
        case .working: working
        case .done: done
        case .idle, .unknown: idle
        }
    }
}

/// Spaces 檢視的一項。
public enum SpacesItem: Identifiable, Equatable, Sendable {
    /// 只有一個 Agent、沒有其他 pane 的 workspace:直接是聊天列。
    case chat(AgentRow)
    /// 兩個以上 Agent,或有 Agent 以外 pane 的 workspace:可收合的群組。
    case group(WorkspaceGroup)

    public var id: String {
        switch self {
        case .chat(let row): row.id
        case .group(let group): group.id
        }
    }
}

extension SpacesItem {
    /// 標出主機(已釘選組):聊天列的副標(第三行)前加主機名，群組帶主機名。
    func prefixingSubtitle(withHost hostLabel: HostLabel) -> SpacesItem {
        switch self {
        case .chat(var row):
            row.hostLabel = hostLabel
            row.subtitle = "\(hostLabel.name) · \(row.subtitle)"
            return .chat(row)
        case .group(var group):
            group.hostName = hostLabel.name
            return .group(group)
        }
    }
}

/// Workspace 群組(#103):收合時只有標頭(名稱、Agent 數、狀態條、各狀態數量),展開後列出 Agent 列與終端機列。
public struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    public var host: HostSelection
    public var workspaceID: String
    /// Workspace 名稱(沒有時是 workspace id)。
    public var label: String
    /// 只算 Agent,終端機另計。
    public var agentCount: Int
    public var terminalCount: Int
    public var counts: SpacesStatusCounts
    /// 收合標頭的狀態條;沒有 Agent 時是空的。
    public var statusBar: [StatusSegment]
    /// Agent 列依狀態(需要你在前),終端機列在後。
    public var rows: [Row]
    /// 展開中(列出 `rows`);收合時只有標頭。
    public var isExpanded: Bool
    /// 在「已釘選」組時的主機名(那組不分主機);主機組裡為 `nil`。
    public var hostName: String?

    /// 主機身分 + workspace id(`w1` 在每台主機都有)。
    public var id: String { "\(host.storedValue)/\(workspaceID)" }

    public init(
        host: HostSelection, workspaceID: String, label: String, agentCount: Int, terminalCount: Int, counts: SpacesStatusCounts,
        statusBar: [StatusSegment] = [], rows: [Row], isExpanded: Bool = false, hostName: String? = nil
    ) {
        self.host = host
        self.workspaceID = workspaceID
        self.label = label
        self.agentCount = agentCount
        self.terminalCount = terminalCount
        self.counts = counts
        self.statusBar = statusBar
        self.rows = rows
        self.isExpanded = isExpanded
        self.hostName = hostName
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
    /// Spaces 檢視(#103):最上面「已釘選」(不分主機),其餘每台主機一組，主機順序同合併列表(選取中主機在前)。
    ///
    /// - 只有一個 Agent、沒有其他 pane → 聊天列;其他(含只有 shell)→ workspace 群組。
    /// - 主機組內：有需要你的在前、再來是工作中，其他依 workspace 編號。
    /// - 已釘選(#41):被釘選的聊天列、或有任一 Agent 被釘選的群組，依釘選時間舊→新(群組以最早釘選的 Agent 為準)。
    /// - 沒有項目的主機組不出現(例如搜尋沒命中)。
    /// - Parameters:
    ///   - visible: 目前開著的聊天(不算未讀)。
    ///   - expansion: 使用者展開(`true`)或收合的群組(以群組 id),覆蓋預設規則;搜尋時是這次搜尋的切換。
    package static func spacesSections(
        sources: [Source], query: String, visible: Set<ChatRoute> = [], expansion: [String: Bool] = [:]
    ) -> [SpacesSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var pinned: [SpacesEntry] = []
        var hostSections: [SpacesSection] = []
        for (hostOrder, source) in sources.enumerated() {
            guard let snapshot = source.snapshot else { continue }
            let context = SpacesContext(
                source: source, snapshot: snapshot, hostOrder: hostOrder, needle: needle, visible: visible, expansion: expansion)
            let entries = context.workspaceIDs.compactMap { spacesEntry(workspaceID: $0, in: context) }
            // 已釘選組不分主機：項目自己標出主機。
            let hostLabel = HostLabel(name: source.name, icon: source.icon)
            pinned += entries.filter { $0.order.pinnedAt != nil }.map { entry in
                var entry = entry
                entry.item = entry.item.prefixingSubtitle(withHost: hostLabel)
                return entry
            }
            let items = entries.filter { $0.order.pinnedAt == nil }.sorted { $0.order.urgencyOrder < $1.order.urgencyOrder }
            guard !items.isEmpty else { continue }
            let counts = SpacesStatusCounts(statuses: context.rows.values.map(\.status))
            let header = SpacesHost(host: source.host, name: source.name, icon: source.icon, counts: counts)
            hostSections.append(SpacesSection(kind: .host(header), items: items.map(\.item)))
        }
        let pinnedItems = pinned.sorted { AgentGroup.pinned.areInIncreasingOrder($0.order, $1.order) }.map(\.item)
        return (pinnedItems.isEmpty ? [] : [SpacesSection(kind: .pinned, items: pinnedItems)]) + hostSections
    }

    private struct SpacesEntry {
        var item: SpacesItem
        /// 已釘選與排序。
        var order: Entry
    }

    /// 一台主機的 snapshot 在 Spaces 檢視要用到的東西(每個 workspace 共用，只算一次)。
    private struct SpacesContext {
        var source: Source
        var snapshot: HostSnapshot
        var hostOrder: Int
        var needle: String
        var visible: Set<ChatRoute>
        var expansion: [String: Bool]
        /// 不帶主機前綴的列(以 pane id):Spaces 檢視以主機組標題表示主機。
        var rows: [String: AgentRow]
        /// 命中搜尋的 Agent pane。
        var matched: Set<String>
        /// Agent 在 snapshot 裡的位置(排序用)。
        var positions: [String: Int]

        init(
            source: Source, snapshot: HostSnapshot, hostOrder: Int, needle: String, visible: Set<ChatRoute>, expansion: [String: Bool]
        ) {
            self.source = source
            self.expansion = expansion
            self.snapshot = snapshot
            self.hostOrder = hostOrder
            self.needle = needle
            self.visible = visible
            var unlabeled = source
            unlabeled.label = nil
            rows = Dictionary(
                AgentListProjection.sections(sources: [unlabeled], query: "", visible: visible).flatMap(\.rows).map { ($0.paneID, $0) },
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

    /// 一個 workspace:只有一個 Agent、沒有其他 pane 是聊天列，否則是群組;搜尋沒命中時 `nil`。
    private static func spacesEntry(workspaceID: String, in context: SpacesContext) -> SpacesEntry? {
        let snapshot = context.snapshot
        let workspace = snapshot.workspaces.first { $0.id == workspaceID }
        let agents = snapshot.agents.filter { $0.workspaceID == workspaceID }
        let shells = snapshot.terminalPanes.filter { $0.workspaceID == workspaceID }
        let label = workspace?.label ?? agents.first?.workspaceLabel ?? workspaceID
        let agentRows = agents.compactMap { context.rows[$0.paneID] }
        let statuses = agentRows.map(\.status)
        // 最急迫的狀態決定主機組內的排序。
        let status: AgentStatus = statuses.contains(.blocked) ? .blocked : statuses.contains(.working) ? .working
            : statuses.first ?? .idle
        // 釘選時間：workspace 裡最早釘選的 Agent(單一 Agent 時就是它的)。
        let order = Entry(
            status: status, hostOrder: context.hostOrder, workspaceOrder: workspace?.number ?? .max,
            position: agents.compactMap { context.positions[$0.paneID] }.min() ?? .max,
            lastMessage: agents.compactMap { context.source.previews[$0.paneID]?.date }.max(),
            pinnedAt: agents.compactMap { ChatUnread.State(agent: $0, source: context.source, visible: context.visible).pinnedAt }.min())

        if agents.count == 1, shells.isEmpty, var row = agentRows.first {
            guard context.matched.contains(row.paneID) else { return nil }
            row.subtitle = label
            return SpacesEntry(item: .chat(row), order: order)
        }
        guard !agents.isEmpty || !shells.isEmpty else { return nil }
        return workspaceGroup(workspaceID: workspaceID, label: label, agentRows: agentRows, shells: shells, in: context)
            .map { SpacesEntry(item: .group($0), order: order) }
    }

    /// workspace 群組。搜尋：命中 workspace 本身(名稱、id、主機名)→ 全部列;否則只留命中的列，都沒命中就是 `nil`(行為規格 F2.3)。
    /// 數量與狀態一律算整個 workspace,不受搜尋影響。
    private static func workspaceGroup(
        workspaceID: String, label: String, agentRows: [AgentRow], shells: [Pane], in context: SpacesContext
    ) -> WorkspaceGroup? {
        let source = context.source
        let terminals = shells.map { TerminalRow(pane: $0, host: source.host, hostLabel: nil) }
        let workspaceHit = context.needle.isEmpty || contains(context.needle, in: [label, workspaceID, source.name])
        let shownAgents = workspaceHit ? agentRows : agentRows.filter { context.matched.contains($0.paneID) }
        let shownTerminals = workspaceHit ? terminals : terminals.filter { contains(context.needle, in: [$0.subtitle]) }
        guard workspaceHit || !shownAgents.isEmpty || !shownTerminals.isEmpty else { return nil }

        // 需要你 > 工作中 > 完成 > 閒置;同狀態依 snapshot 位置(sorted 不保證穩定，明確比位置)。
        let sortedAgents = shownAgents.sorted {
            ($0.status.urgencyRank, context.positions[$0.paneID] ?? .max) < ($1.status.urgencyRank, context.positions[$1.paneID] ?? .max)
        }
        let rows = sortedAgents.map { row in
            var row = row
            row.subtitle = AgentKind(rawKind: row.kind).displayName ?? ""
            return WorkspaceGroup.Row.agent(row)
        } + shownTerminals.map(WorkspaceGroup.Row.terminal)
        let counts = SpacesStatusCounts(statuses: agentRows.map(\.status))
        var group = WorkspaceGroup(
            host: source.host, workspaceID: workspaceID, label: label, agentCount: agentRows.count, terminalCount: shells.count,
            counts: counts, statusBar: statusSegments(agentRows.map(\.status)), rows: rows)
        // 搜尋時命中的預設展開;否則預設只展開有需要你或工作中的。使用者的切換優先。
        let expandedByDefault = !context.needle.isEmpty || counts.needsYou > 0 || counts.working > 0
        group.isExpanded = context.expansion[group.id] ?? expandedByDefault
        return group
    }

    /// 狀態條：20 個以內每個 Agent 一段(需要你 > 工作中 > 完成 > 閒置);超過時依狀態合併，段長與數量成正比。
    static func statusSegments(_ statuses: [AgentStatus]) -> [StatusSegment] {
        let ranked = statuses.map(\.urgencyStatus).sorted { $0.urgencyRank < $1.urgencyRank }
        guard ranked.count > 20 else { return ranked.map { StatusSegment(status: $0, weight: 1) } }
        var merged: [StatusSegment] = []
        for status in ranked {
            if merged.last?.status == status {
                merged[merged.count - 1].weight += 1
            } else {
                merged.append(StatusSegment(status: status, weight: 1))
            }
        }
        return merged
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
