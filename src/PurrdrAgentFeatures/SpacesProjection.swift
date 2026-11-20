import Foundation
import PurrdrCore

/// Agent 列表的兩種檢視(行為規格 F2.1、#37 故事 7–14)。
public enum AgentListMode: String, CaseIterable, Sendable {
    /// 每台主機的每個 workspace 一段，段內每個 Tab 一列(#275)。
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

/// 存在 `UserDefaults`。未知或缺值回 `nil`(呼叫端用 Agents)。
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

/// Spaces 檢視的一段(#275,原型 purrdr-screens 定案版):一台主機上的一個 workspace,段內每個 Tab 一列。
public struct SpacesSection: Identifiable, Equatable, Sendable {
    public var host: HostSelection
    public var hostName: String
    public var hostIcon: HostIcon
    public var workspaceID: String
    /// Workspace 名稱(沒有時是 workspace id)。
    public var workspace: String
    public var tabs: [SpacesTab]

    /// 主機身分 + workspace id(`w1` 在每台主機都有)。
    public var id: String { "\(host.storedValue)/\(workspaceID)" }

    public init(
        host: HostSelection, hostName: String, hostIcon: HostIcon, workspaceID: String, workspace: String, tabs: [SpacesTab]
    ) {
        self.host = host
        self.hostName = hostName
        self.hostIcon = hostIcon
        self.workspaceID = workspaceID
        self.workspace = workspace
        self.tabs = tabs
    }
}

/// Spaces 檢視的一列：一個 Tab(herdr 沒有回報 Tab 的 pane 自成一列)。
public struct SpacesTab: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// 只有一個 pane:直接開(Agent 開對話、其他開 Pane 終端機，同一個 `ChatRoute` 由畫面分辨)。
        case pane(ChatRoute)
        /// 多個 pane:開那個 Tab 的版面圖選 Pane。
        case layout(workspaceID: String, tabID: String)
    }

    public var host: HostSelection
    /// Tab id;沒有 Tab 的 pane 是 pane id。
    public var key: String
    public var title: String
    public var target: Target

    public var id: String { "\(host.storedValue)/\(key)" }

    public init(host: HostSelection, key: String, title: String, target: Target) {
        self.host = host
        self.key = key
        self.title = title
        self.target = target
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
    /// Spaces 檢視(#275):每台主機(順序同合併列表)的每個 workspace(依主機上的順序)一段，段內每個 Tab 一列(依 Tab 順序)。
    /// 沒有任何 pane 的 workspace 不出現。Spaces 檢視沒有搜尋與釘選。
    package static func spacesSections(sources: [Source]) -> [SpacesSection] {
        sources.flatMap { source -> [SpacesSection] in
            guard let snapshot = source.snapshot else { return [] }
            var workspaceIDs = snapshot.workspaces.sorted { $0.number < $1.number }.map(\.id)
            for id in snapshot.agents.map(\.workspaceID) + snapshot.panes.map(\.workspaceID) where !workspaceIDs.contains(id) {
                workspaceIDs.append(id)
            }
            return workspaceIDs.compactMap { workspaceID in
                let tabs = spacesTabs(workspaceID: workspaceID, host: source.host, snapshot: snapshot)
                guard !tabs.isEmpty else { return nil }
                let agent = snapshot.agents.first { $0.workspaceID == workspaceID }
                let label = snapshot.workspaces.first { $0.id == workspaceID }?.label ?? agent.map(AgentRowText.workspaceName) ?? workspaceID
                return SpacesSection(
                    host: source.host, hostName: source.name, hostIcon: source.icon, workspaceID: workspaceID, workspace: label, tabs: tabs)
            }
        }
    }

    /// 一個 workspace 的 Tab 列：herdr 回報的 Tab(有 pane 的才列),加上沒有 Tab 的 pane(各自一列)。
    private static func spacesTabs(workspaceID: String, host: HostSelection, snapshot: HostSnapshot) -> [SpacesTab] {
        let agents = snapshot.agents.filter { $0.workspaceID == workspaceID }
        var panes = snapshot.panes.filter { $0.workspaceID == workspaceID }
        // 只出現在 agents 的 pane(舊版 herdr 的 panes 不含 agent)也算。
        for agent in agents where !panes.contains(where: { $0.id == agent.paneID }) {
            panes.append(Pane(id: agent.paneID, workspaceID: workspaceID, tabID: agent.tabID ?? ""))
        }
        func tabID(of pane: Pane) -> String? {
            let id = pane.tabID.isEmpty ? agents.first { $0.paneID == pane.id }?.tabID : pane.tabID
            return id.flatMap { $0.isEmpty ? nil : $0 }
        }
        let tabs = snapshot.tabs.filter { $0.workspaceID == workspaceID }.sorted { $0.number < $1.number }
        var rows: [SpacesTab] = tabs.enumerated().compactMap { index, tab in
            let tabPanes = panes.filter { tabID(of: $0) == tab.id }
            guard let first = tabPanes.first else { return nil }
            let target: SpacesTab.Target = tabPanes.count == 1
                ? .pane(ChatRoute(host: host, paneID: first.id)) : .layout(workspaceID: workspaceID, tabID: tab.id)
            let tabAgents = tabPanes.compactMap { pane in agents.first { $0.paneID == pane.id } }
            let contents = tabAgents.first.map { agent in
                let title = AgentRowText.title(for: agent, siblings: agents)
                return tabAgents.count > 1 ? "\(title) +\(tabAgents.count - 1)" : title
            } ?? TerminalRow(pane: first, host: host, hostLabel: nil).program
            return SpacesTab(host: host, key: tab.id, title: tabTitle(tab.label, contents: contents, position: index + 1), target: target)
        }
        let known = Set(tabs.map(\.id))
        for pane in panes where tabID(of: pane).map({ !known.contains($0) }) ?? true {
            let title = agents.first { $0.paneID == pane.id }.map { AgentRowText.title(for: $0, siblings: agents) }
                ?? TerminalRow(pane: pane, host: host, hostLabel: nil).program
            rows.append(SpacesTab(host: host, key: pane.id, title: title, target: .pane(ChatRoute(host: host, paneID: pane.id))))
        }
        return rows
    }

    /// Tab 名稱：人取的照原文;沒有名稱或是 herdr 的預設數字名稱(「1」「2」…)時用 Tab 裡的內容
    /// (第一個 Agent 的聊天標題，多個時加「+N」;只有終端機時是程式名);都沒有才是「Tab N」(N 是在 workspace 裡的順序)。
    package static func tabTitle(_ label: String?, contents: String?, position: Int) -> String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, !label.allSatisfy(\.isNumber) {
            return label
        }
        if let contents, !contents.isEmpty { return contents }
        return String(localized: "Tab \(position)")
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
