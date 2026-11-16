import Foundation
import Observation
import PurrdrCore

/// 一台主機讀不到時，列表下方的一行(#37 故事 3)。
public struct HostFailure: Equatable, Sendable {
    public var host: HostSelection
    public var name: String
    public var message: String

    public init(host: HostSelection, name: String, message: String) {
        self.host = host
        self.name = name
        self.message = message
    }

    /// 「主機名：原因」。
    public var text: String { String(localized: "\(name): \(message)") }
}

/// 所有主機合併成的 Agent 列表(#39;取代 #10「切換目前主機」只看一台)。
///
/// - 每台主機各自一個 `AgentListModel`:各自連線、各自事件訂閱、各自錯誤與退避;一台連不上不影響其他台。
/// - 連不上的主機保留最後讀到的列，列表下方顯示「主機名：原因」。
/// - 選取中主機只決定排序(在前)、哪些列不標示主機名，以及沒有任何列時誰的錯誤佔滿畫面。
@MainActor
@Observable
public final class MergedAgentListModel {
    /// 畫面要呈現的內容。
    public enum Content: Equatable {
        case loading
        /// 沒有任何列，選取中主機讀不到:錯誤佔滿畫面。
        case failed(String)
        /// 所有主機都讀到了，沒有 Agent。
        case empty
        case list
    }

    /// 一台主機：名稱、圖示、它的列表與列操作。
    public struct Source {
        public let host: HostSelection
        public let name: String
        public let icon: HostIcon
        public let list: AgentListModel
        public let actions: WorkspaceActionsModel
    }

    /// 選取中主機在前，其他依主機清單順序。
    public private(set) var sources: [Source] = []
    public private(set) var selected: HostSelection = .demo
    /// 搜尋字串(所有主機共用)。空白時列出全部。
    public var query = ""
    /// 要直接開的聊天：從版面圖選了 Agent,或點了推播通知(#29)。畫面推入後設回 `nil`。
    public var openedChat: ChatRoute?
    /// 列表檢視(Spaces／Agents);改了就存起來，重新啟動後沿用。兩種檢視共用搜尋、分組、已讀與釘選。
    public var mode: AgentListMode {
        didSet { if mode != oldValue { modeStore.save(mode) } }
    }

    private let modeStore: any AgentListModeStore

    public init(modeStore: any AgentListModeStore = InMemoryAgentListModeStore()) {
        self.modeStore = modeStore
        // 未知或缺值一律回到 Spaces(行為規格 F2.1)。
        mode = modeStore.load() ?? .spaces
    }

    func update(sources: [Source], selected: HostSelection) {
        self.selected = selected
        self.sources = sources.filter { $0.host == selected } + sources.filter { $0.host != selected }
    }

    /// 合併後依「需要你／工作中／閒置」分組、套用搜尋的列表。
    public var sections: [AgentSection] {
        AgentListProjection.sections(
            sources: sources.map { source in
                AgentListProjection.Source(
                    host: source.host, label: source.host == selected ? nil : HostLabel(name: source.name, icon: source.icon),
                    snapshot: source.list.snapshot, previews: source.list.previews)
            },
            query: query)
    }

    /// Spaces 檢視：每個 workspace 一項，依同樣的分組與搜尋。
    public var spacesSections: [SpacesSection] {
        AgentListProjection.spacesSections(sources: projectionSources, query: query)
    }

    private var projectionSources: [AgentListProjection.Source] {
        sources.map { source in
            AgentListProjection.Source(
                host: source.host, label: source.host == selected ? nil : HostLabel(name: source.name, icon: source.icon),
                snapshot: source.list.snapshot, previews: source.list.previews)
        }
    }

    /// 任何一台主機有 Agent(不看搜尋)。沒有時不顯示搜尋欄。
    public var hasAgents: Bool { sources.contains { $0.list.hasAgents } }

    /// 讀不到的主機(保留它最後的列)。
    public var failures: [HostFailure] {
        sources.compactMap { source in
            guard case .failed(let message) = source.list.phase else { return nil }
            return HostFailure(host: source.host, name: source.name, message: message)
        }
    }

    public var content: Content {
        if hasAgents { return .list }
        if case .failed(let message)? = list(for: selected)?.phase { return .failed(message) }
        if sources.contains(where: { $0.list.phase == .loading }) { return .loading }
        return failures.isEmpty ? .empty : .list
    }

    /// 即時更新要跟著重來的主機集合(主機新增、刪除、編輯時改變)。
    public var runKey: [ObjectIdentifier] { sources.map { ObjectIdentifier($0.list) } }

    public func list(for host: HostSelection) -> AgentListModel? {
        sources.first { $0.host == host }?.list
    }

    public func actions(for host: HostSelection) -> WorkspaceActionsModel? {
        sources.first { $0.host == host }?.actions
    }

    public func snapshot(for host: HostSelection) -> HostSnapshot? {
        list(for: host)?.snapshot
    }

    /// pane 不是 Agent(終端機列、版面圖的終端機方塊)時，它的 Pane 終端機標題(程式名);Agent 的 pane 或找不到時為 `nil`。
    /// 列表與對話欄以同一個 `ChatRoute` 導覽，靠這個決定開對話還是開 Pane 終端機。
    public func terminalTitle(of route: ChatRoute) -> String? {
        guard let snapshot = snapshot(for: route.host), !snapshot.agents.contains(where: { $0.paneID == route.paneID }),
              let pane = snapshot.panes.first(where: { $0.id == route.paneID }) else { return nil }
        return TerminalRow(pane: pane, host: route.host, hostLabel: nil).program
    }

    /// 列表看到的 session(開對話時用來比對快取)。
    public func sessionID(of route: ChatRoute) -> String? {
        list(for: route.host)?.sessionID(ofPane: route.paneID)
    }

    /// 每台主機各讀一次(同時進行)。
    public func load() async {
        let lists = sources.map(\.list)
        await withTaskGroup(of: Void.self) { group in
            for list in lists { group.addTask { await list.load() } }
        }
    }

    /// 每台主機各自的即時更新，同時進行，直到所在的 task 被取消。一台卡在退避不會擋住其他台。
    ///
    /// iPad 多視窗時每個視窗都會呼叫;每台主機的迴圈經 `AgentListModel.liveUpdates` 共用，各只跑一份(#31)。
    public func run() async {
        let lists = sources.map(\.list)
        await withTaskGroup(of: Void.self) { group in
            for list in lists { group.addTask { await list.liveUpdates.attach() } }
        }
    }

    /// 網路恢復、回到前景：每台主機都跳過退避立刻重連。
    public func retryNow() {
        for source in sources { source.list.retryNow() }
    }

    /// 「再試一次」:讀不到的主機各自重試(取消 Tailscale 重新驗證而停著的，重新開始即時更新)。
    public func retry() {
        for source in sources {
            guard case .failed = source.list.phase else { continue }
            if source.list.isWaitingForRetry {
                Task { await source.list.load() }
            } else {
                source.list.retryNow()
            }
        }
    }
}
