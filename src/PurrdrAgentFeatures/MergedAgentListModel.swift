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

/// 一台還沒讀到或讀不到的主機在列表上的狀態列(#221)。
public struct HostLoadStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// 連線中(第一次載入或按了再試一次)。
        case connecting
        /// 連線超過 `slowConnectionThreshold`:仍在連線，提供再試一次。
        case stillConnecting
    }

    public var host: HostSelection
    public var name: String
    public var icon: HostIcon
    public var state: State

    public init(host: HostSelection, name: String, icon: HostIcon, state: State) {
        self.host = host
        self.name = name
        self.icon = icon
        self.state = state
    }
}

/// 所有主機合併成的 Agent 列表(#39;取代 #10「切換目前主機」只看一台)。
///
/// - 每台主機各自一個 `AgentListModel`:各自連線、各自事件訂閱、各自錯誤與退避;一台連不上不影響其他台。
/// - 連不上的主機保留最後讀到的列，列表下方顯示「主機名：原因」。
/// - 選取中主機只決定排序(在前)、哪些列不標示主機名，以及每台都讀不到時誰的錯誤佔滿畫面。
@MainActor
@Observable
public final class MergedAgentListModel {
    /// 畫面要呈現的內容。
    public enum Content: Equatable {
        /// 第一次載入、還沒有任何列：列表骨架與各主機的連線狀態(不整頁轉圈,#221)。
        case loading
        /// 裝置沒有網路、也沒有任何列：離線畫面與再試一次(不等連線逾時,#221)。
        case offline
        /// 沒有任何列，每台主機都讀不到:選取中主機的錯誤佔滿畫面。
        case failed(String)
        /// 所有主機都讀到了，沒有 Agent。
        case empty
        /// Agents 檢視沒有 Agent,但有終端機(Spaces 檢視看得到):說明並提供切到 Spaces。
        case noAgentsInAgentsView
        case list
    }

    /// 一台主機：名稱、圖示、它的列表與列操作、它的「You should know」註記(#23)。
    public struct Source {
        public let host: HostSelection
        public let name: String
        public let icon: HostIcon
        public let list: AgentListModel
        public let actions: WorkspaceActionsModel
        public var notes: YouShouldKnowModel?

        package init(
            host: HostSelection, name: String, icon: HostIcon, list: AgentListModel, actions: WorkspaceActionsModel,
            notes: YouShouldKnowModel? = nil
        ) {
            self.host = host
            self.name = name
            self.icon = icon
            self.list = list
            self.actions = actions
            self.notes = notes
        }
    }

    /// 註記清單的一則：註記、所屬聊天(主機 + pane)與 Agent 標題。
    public struct NoteEntry: Identifiable {
        public let note: YouShouldKnowNote
        public let route: ChatRoute
        public let title: String
        public var id: String { "\(route.host.storedValue)/\(note.id)" }
    }

    /// 選取中主機在前，其他依主機清單順序。
    public private(set) var sources: [Source] = []
    public private(set) var selected: HostSelection = .demo
    /// 搜尋字串(所有主機共用)。空白時列出全部。
    public var query = "" {
        didSet {
            if query != oldValue { searchExpansion = [:] }
        }
    }
    /// 要直接開的聊天：從版面圖選了 Agent,或點了推播通知(#29)。畫面推入後設回 `nil`。
    public var openedChat: ChatRoute?
    /// 目前開著的聊天(iPhone 推入的對話、iPad 每個視窗開在旁邊或新視窗開的):永遠不算未讀，也不算進需處理數量
    /// (行為規格 F2.6、F2.8)。以次數記：同一個聊天開在兩個視窗，關掉一個仍算開著。
    private var visibleCounts: [ChatRoute: Int] = [:]
    public var visibleChats: Set<ChatRoute> { Set(visibleCounts.keys) }
    /// 列表底部的滑動操作提示：第一次用滑動面板的動作之前顯示(行為規格 F2.7)。
    public private(set) var showsSwipeHint: Bool
    private let swipeHint: any SwipeHintStore
    /// 列表檢視(Spaces／Agents);改了就存起來，重新啟動後沿用。兩種檢視共用搜尋、分組、已讀與釘選。
    /// 版面事件只在 Spaces 檢視訂閱(#40),所以換檢視時每台主機的即時更新跟著換訂閱。
    public var mode: AgentListMode {
        didSet {
            guard mode != oldValue else { return }
            modeStore.save(mode)
            applyLayoutSubscription()
        }
    }

    /// 主機篩選(#244);`nil` 是所有主機。選某台主機時同時設成選取中主機，選回所有主機時選取中主機不變。
    public var hostFilter: HostSelection? {
        didSet {
            if let hostFilter, hostFilter != oldValue { selectHost?(hostFilter) }
        }
    }
    /// 篩選選了某台主機時，把它設成選取中主機(主機清單接上)。
    public var selectHost: (@MainActor (HostSelection) -> Void)?

    /// 篩選選單的主機項目(依列表的主機順序)。
    public var hostFilterOptions: [HostOption] {
        sources.map { HostOption(id: $0.host, name: $0.name, icon: $0.icon) }
    }

    /// Agents 檢視的單一清單：依分組順序(已釘選、需要你、工作中、閒置)接成一份。
    public var agentRows: [AgentRow] { sections.flatMap(\.rows) }

    /// 某台主機的名稱與圖示(列首的主機圖示、預覽前的主機名;選取中主機也有)。
    public func hostLabel(of host: HostSelection) -> HostLabel? {
        sources.first { $0.host == host }.map { HostLabel(name: $0.name, icon: $0.icon) }
    }

    private let modeStore: any AgentListModeStore
    /// Spaces 群組的手動展開狀態(以群組 id):只在記憶體，App 結束就忘記(#103)。
    private var expansion: [String: Bool] = [:]
    /// 這次搜尋期間點標頭的切換;搜尋字改變或清空就丟掉，不動 `expansion`。
    private var searchExpansion: [String: Bool] = [:]

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(swipeHint: any SwipeHintStore = InMemorySwipeHintStore(), modeStore: any AgentListModeStore = InMemoryAgentListModeStore()) {
        self.swipeHint = swipeHint
        showsSwipeHint = !swipeHint.isDismissed
        self.modeStore = modeStore
        // 未知或缺值(新安裝)一律是 Agents。
        mode = modeStore.load() ?? .agents
    }

    /// 對話出現在畫面上：記下開啟時間(這之前的回覆都算讀過)。
    public func chatAppeared(_ route: ChatRoute) {
        visibleCounts[route, default: 0] += 1
        markOpened(route)
    }

    /// 對話離開畫面：再記一次開啟時間(看著的時候來的回覆也算讀過)。
    public func chatDisappeared(_ route: ChatRoute) {
        markOpened(route)
        if let count = visibleCounts[route] { visibleCounts[route] = count > 1 ? count - 1 : nil }
    }

    /// 以列表看到的 session 記開啟時間;沒有 session 時不記(行為規格 F2.6:否則下一個用這個 pane 的聊天會被當成讀過)。
    private func markOpened(_ route: ChatRoute) {
        guard let session = snapshot(for: route.host)?.agents.first(where: { $0.paneID == route.paneID })?.sessionID else { return }
        actions(for: route.host)?.markOpened(sessionID: session, seen: list(for: route.host)?.previews[route.paneID]?.date)
    }

    /// 使用者第一次用了滑動面板的動作：之後不再顯示提示(SwiftUI 沒有「面板滑開」的訊號，以第一次使用代替)。
    public func swipeActionUsed() {
        guard showsSwipeHint else { return }
        showsSwipeHint = false
        swipeHint.dismiss()
    }

    /// 需要處理的 workspace 數(導覽入口的數字;不設 app 圖示徽章)。
    public var attentionCount: Int { ChatUnread.attentionCount(sources: projectionSources, visible: visibleChats) }

    package func update(sources: [Source], selected: HostSelection) {
        self.selected = selected
        self.sources = sources.filter { $0.host == selected } + sources.filter { $0.host != selected }
        if let hostFilter, !sources.contains(where: { $0.host == hostFilter }) { self.hostFilter = nil }
        applyLayoutSubscription()
    }

    private func applyLayoutSubscription() {
        for source in sources { source.list.subscribesToLayout = mode == .spaces }
    }

    /// 合併後依「需要你／工作中／閒置」分組、套用搜尋的列表。
    public var sections: [AgentSection] {
        AgentListProjection.sections(sources: filteredProjectionSources, query: query, visible: visibleChats)
    }

    /// 套用主機篩選後的來源。
    private var filteredProjectionSources: [AgentListProjection.Source] {
        guard let hostFilter else { return projectionSources }
        return projectionSources.filter { $0.host == hostFilter }
    }

    private var projectionSources: [AgentListProjection.Source] {
        sources.map { source in
            AgentListProjection.Source(
                host: source.host, label: source.host == selected ? nil : HostLabel(name: source.name, icon: source.icon),
                name: source.name, icon: source.icon, snapshot: source.list.snapshot, previews: source.list.previews, preferences: source.actions.preferences)
        }
    }

    /// Spaces 檢視：每個 workspace 一項，依同樣的分組與搜尋。
    public var spacesSections: [SpacesSection] {
        AgentListProjection.spacesSections(
            sources: filteredProjectionSources, query: query, visible: visibleChats, expansion: isSearching ? searchExpansion : expansion)
    }

    /// 點群組標頭：展開或收合。搜尋時只記在這次搜尋，不改手動狀態。
    public func toggleExpanded(_ group: WorkspaceGroup) {
        if isSearching {
            searchExpansion[group.id] = !group.isExpanded
        } else {
            expansion[group.id] = !group.isExpanded
        }
    }

    /// 任何一台主機有 Agent(不看搜尋)。沒有時不顯示搜尋欄。
    public var hasAgents: Bool { sources.contains { $0.list.hasAgents } }

    /// 讀不到的主機(保留它最後的列)。
    public var failures: [HostFailure] {
        sources.compactMap { source in
            guard hostFilter == nil || source.host == hostFilter, case .failed(let message) = source.list.phase else { return nil }
            return HostFailure(host: source.host, name: source.name, message: message)
        }
    }

    /// 裝置有沒有網路(網路路徑監看提供;沒有時不等連線逾時就顯示離線)。
    public var isNetworkAvailable = true

    /// 連線多久沒有結果就顯示「仍在連線」與再試一次。
    public static let slowConnectionThreshold: TimeInterval = 10

    /// 還在連線的主機，各一行狀態(依主機順序)。
    public func hostStatuses(at now: Date) -> [HostLoadStatus] {
        sources.compactMap { source in
            // 沒網路時連不上是確定的：列表只顯示離線，不逐台顯示連線中。
            guard isNetworkAvailable, hostFilter == nil || source.host == hostFilter, source.list.phase == .loading else { return nil }
            let elapsed = now.timeIntervalSince(source.list.updates.connectingSince)
            let state: HostLoadStatus.State = elapsed >= Self.slowConnectionThreshold ? .stillConnecting : .connecting
            return HostLoadStatus(host: source.host, name: source.name, icon: source.icon, state: state)
        }
    }

    /// 任何一台主機有 Agent 以外的 pane(終端機;Spaces 檢視的卡片看得到)。
    private var hasTerminals: Bool {
        sources.contains { $0.list.snapshot?.terminalPanes.isEmpty == false }
    }

    public var content: Content {
        if hasAgents { return .list }
        if !isNetworkAvailable { return .offline }
        if let message = allFailedMessage { return .failed(message) }
        if sources.contains(where: { $0.list.phase == .loading }) { return .loading }
        if hasTerminals { return mode == .spaces ? .list : .noAgentsInAgentsView }
        return failures.isEmpty ? .empty : .list
    }

    /// 每台主機都讀不到時，佔滿畫面的錯誤：選取中主機的(#221:只有一部分讀不到時錯誤留在那台主機的狀態行)。
    private var allFailedMessage: String? {
        let messages = sources.map { source -> String? in
            if case .failed(let message) = source.list.phase { return message }
            return nil
        }
        guard !messages.isEmpty, messages.allSatisfy({ $0 != nil }) else { return nil }
        if case .failed(let message)? = list(for: selected)?.phase { return message }
        return messages.first ?? nil
    }

    /// 所有主機的「You should know」註記(#23):只算列表裡有的 Claude 聊天(以完整 session id 配對)。
    /// 依主機順序(選取中主機在前)、每台主機內新→舊。
    public var notes: [NoteEntry] {
        let allRows = AgentListProjection.sections(sources: projectionSources, query: query, visible: visibleChats).flatMap(\.rows)
        let titles = Dictionary(allRows.map { ($0.route, $0.title) }) { first, _ in first }
        return sources.flatMap { source -> [NoteEntry] in
            guard let model = source.notes else { return [] }
            let panes = source.list.claudeSessionPanes
            return model.notes.compactMap { note in
                guard let paneID = panes[note.sessionID] else { return nil }
                let route = ChatRoute(host: source.host, paneID: paneID)
                return NoteEntry(note: note, route: route, title: titles[route] ?? paneID)
            }
        }
    }

    /// 每台主機各自輪詢註記，直到所在的 task 被取消。與聊天輸入列共用同一個讀取迴圈(`YouShouldKnowModel.liveUpdates`)。
    public func runNotes() async {
        let models = sources.compactMap(\.notes)
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.liveUpdates.attach() } }
        }
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
        guard let pane = snapshot(for: route.host)?.terminalPanes.first(where: { $0.id == route.paneID }) else { return nil }
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

    /// 「再試一次」:讀不到的主機各自重試並改回連線中(取消 Tailscale 重新驗證而停著的，重新開始即時更新);
    /// 還在連的主機丟掉卡住的連線重新開始(#221)。
    public func retry() {
        for source in sources where source.list.phase != .loaded {
            if source.list.isWaitingForRetry {
                Task { await source.list.load() }
            } else {
                source.list.retry()
            }
        }
    }
}
