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
        /// 還沒有加入任何主機、也沒試用 Demo(#332):說明與「新增主機」「試用 Demo」按鈕。
        case noHosts
        /// 裝置沒有網路、也沒有任何列：離線畫面與再試一次(不等連線逾時,#221)。
        case offline
        /// 沒有任何列，每台主機都讀不到:選取中主機的錯誤佔滿畫面。
        case failed(String)
        /// 所有主機都讀到了，沒有 Agent。
        case empty
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
        /// 同步改了位址或 host key,等使用者重新確認(#572)。
        public let needsReconfirmation: Bool

        package init(
            host: HostSelection, name: String, icon: HostIcon, list: AgentListModel, actions: WorkspaceActionsModel,
            notes: YouShouldKnowModel? = nil, needsReconfirmation: Bool = false
        ) {
            self.host = host
            self.name = name
            self.icon = icon
            self.list = list
            self.actions = actions
            self.notes = notes
            self.needsReconfirmation = needsReconfirmation
        }
    }

    /// 選取中主機在前，其他依主機清單順序。
    public private(set) var sources: [Source] = []
    public private(set) var selected: HostSelection = .demo
    /// 搜尋字串(所有主機共用)。空白時列出全部。
    public var query = ""
    /// 目前開著的聊天(iPhone 推入的對話、iPad 每個視窗開在旁邊或新視窗開的):永遠不算未讀，也不算進需處理數量
    /// (行為規格 F2.6、F2.8)。以次數記：同一個聊天開在兩個視窗，關掉一個仍算開著。
    private var visibleCounts: [ChatRoute: Int] = [:]
    public var visibleChats: Set<ChatRoute> { Set(visibleCounts.keys) }
    /// 目前主機(#334):全 app 共用的主機範圍，`nil` 是所有主機;列表的主機篩選只是改它的控制。
    /// 選某台主機時同時設成選取中主機，選回所有主機時選取中主機不變。
    public var currentHost: HostSelection? {
        didSet {
            guard currentHost != oldValue else { return }
            currentHostDidChange?(currentHost)
            if let currentHost { selectHost?(currentHost) }
        }
    }
    /// 跨聊天「需要你」通知的輸出(返回鈕小點等);由 app 層(`PurrdrApp` 的 scenePhase)以 `needsYou.drive(observing:isActive:)` 驅動(整個 app 唯一的接線點,#530、#589);列表段落(#531)只讀輸出。
    public let needsYou = NeedsYouNotifications()

    /// 目前主機改變時通知(主機清單接上，存到本機)。
    public var currentHostDidChange: (@MainActor (HostSelection?) -> Void)?
    /// 目前主機是某台主機時，把它設成選取中主機(主機清單接上)。
    public var selectHost: (@MainActor (HostSelection) -> Void)?
    /// 沒有主機時等著第一台主機(#332):由 `HostsModel` 依「沒有已存主機、也還沒試用 Demo」設定。
    public var isAwaitingFirstHost = false
    /// 空狀態的「試用 Demo」:由 `HostsModel` 接上。
    public var enterDemo: (@MainActor () -> Void)?

    /// 篩選選單的主機項目(依列表的主機順序)。
    public var hostFilterOptions: [HostOption] {
        sources.map { HostOption(id: $0.host, name: $0.name, icon: $0.icon, needsReconfirmation: $0.needsReconfirmation) }
    }

    /// 每個 Agent 一列、依分組順序(已釘選、需要你、工作中、閒置)接成一份:離開期間輪數與未讀折算的資料來源，不是畫面上的檢視。
    public var agentRows: [AgentRow] { sections.flatMap(\.rows) }

    /// 某台主機的名稱與圖示(列首的主機圖示、預覽前的主機名;選取中主機也有)。
    public func hostLabel(of host: HostSelection) -> HostLabel? {
        sources.first { $0.host == host }.map { HostLabel(name: $0.name, icon: $0.icon) }
    }

    /// 離開期間的輪數讀取(路徑與開啟時間 → 輪數);`nil` 時由各主機的列表讀對話紀錄(#308)。
    @ObservationIgnored public var awayTurnCounter: (@MainActor (ChatRoute, Date) async -> Int?)?
    /// 已算出的輪數,依「聊天 + 開啟時間」;開啟時間變了(又進過聊天)就作廢。
    private var awayTurnCounts: [ChatRoute: (openedAt: Date, turns: Int)] = [:]

    /// 替有「離開期間」徽章的列算輪數(每個聊天、每個開啟時間只算一次;畫面在列表出現與列變動時呼叫)。
    public func refreshAwayTurns() async {
        let visible = visibleChats
        for source in sources {
            guard let snapshot = source.list.snapshot else { continue }
            let projection = projectionSource(of: source)
            for agent in snapshot.agents {
                let route = ChatRoute(host: source.host, paneID: agent.paneID)
                guard ChatUnread.State(agent: agent, source: projection, visible: visible).isAway,
                      let session = agent.sessionID, let openedAt = source.actions.preferences.opened[session] else { continue }
                if awayTurnCounts[route]?.openedAt == openedAt { continue }
                let turns: Int?
                if let awayTurnCounter {
                    turns = await awayTurnCounter(route, openedAt)
                } else {
                    turns = await source.list.awayTurns(paneID: agent.paneID, openedAt: openedAt)
                }
                if let turns { awayTurnCounts[route] = (openedAt, turns) }
            }
        }
    }

    private let skeletonRowCounts: any SkeletonRowCountStore

    /// 第一次載入時骨架的列數:取上次列表的列數(#496)。
    public var loadingRowCount: Int { SkeletonLoading.rowCount(lastCount: skeletonRowCounts.load(.agentList)) }

    /// 列表有列時記住列數,下次冷啟動的骨架照這個數量。
    public func rememberRowCount() { rememberRowCount(of: spacesSections) }

    /// 列的總數(骨架列數與「列數變了」的判斷共用)。
    public static func rowCount(of sections: [SpacesSection]) -> Int { sections.reduce(0) { $0 + $1.tabs.count } }

    /// 用畫面已算好的段落記列數,不必再投影一次。
    public func rememberRowCount(of sections: [SpacesSection]) {
        let count = Self.rowCount(of: sections)
        if count > 0, skeletonRowCounts.load(.agentList) != count { skeletonRowCounts.save(count, for: .agentList) }
    }

    public init(skeletonRowCounts: any SkeletonRowCountStore = InMemorySkeletonRowCountStore()) {
        self.skeletonRowCounts = skeletonRowCounts
    }

    /// 對話出現在畫面上：記下開啟時間(這之前的回覆都算讀過)。
    public func chatAppeared(_ route: ChatRoute) {
        // 第一個視窗進來時，先記下上次離開的時間(markOpened 會蓋掉它)，離開期間摘要要用(#308)。
        if visibleCounts[route] == nil, let opened = openedAt(route) { awayStarts[route] = opened }
        visibleCounts[route, default: 0] += 1
        markOpened(route)
    }

    /// 這個聊天這次開著之前，上次離開的時間(#308)。開著期間不變;只有進聊天(`chatAppeared`)之後才有，沒開過的聊天是 `nil`。
    public func awayStart(for route: ChatRoute) -> Date? { awayStarts[route] }

    private var awayStarts: [ChatRoute: Date] = [:]

    private func openedAt(_ route: ChatRoute) -> Date? {
        guard let session = snapshot(for: route.host)?.agents.first(where: { $0.paneID == route.paneID })?.sessionID else { return nil }
        return actions(for: route.host)?.preferences.opened[session]
    }

    /// 對話離開畫面：再記一次開啟時間(看著的時候來的回覆也算讀過)。
    public func chatDisappeared(_ route: ChatRoute) {
        markOpened(route)
        if let count = visibleCounts[route] { visibleCounts[route] = count > 1 ? count - 1 : nil }
        if visibleCounts[route] == nil { awayStarts[route] = nil }
    }

    /// 以列表看到的 session 記開啟時間;沒有 session 時不記(行為規格 F2.6:否則下一個用這個 pane 的聊天會被當成讀過)。
    private func markOpened(_ route: ChatRoute) {
        guard let agents = snapshot(for: route.host)?.agents,
              let session = agents.first(where: { $0.paneID == route.paneID })?.sessionID else { return }
        actions(for: route.host)?.markOpened(
            sessionID: session, seen: list(for: route.host)?.previews[route.paneID]?.date,
            liveSessions: Set(agents.compactMap(\.sessionID)))
    }

    /// 需要處理的 workspace 數(導覽入口的數字;不設 app 圖示徽章)。
    public var attentionCount: Int { ChatUnread.attentionCount(sources: projectionSources, visible: visibleChats) }

    /// 「需要你」(blocked)的 Agent 數:聊天 tab 的 badge(#390)。所有主機合計,不受主機篩選影響;
    /// `excluding` 是要排除的聊天(目前沒有畫面使用;返回鈕旁的「另外 N 個」徽章已移除,通知方式重新設計中)。
    public func needsYouCount(excluding route: ChatRoute? = nil) -> Int {
        sources.reduce(0) { count, source in
            guard let agents = source.list.snapshot?.agents else { return count }
            return count + agents.filter { $0.effectiveStatus == .blocked && ChatRoute(host: source.host, paneID: $0.paneID) != route }.count
        }
    }

    package func update(sources: [Source], selected: HostSelection) {
        self.selected = selected
        self.sources = sources.filter { $0.host == selected } + sources.filter { $0.host != selected }
        if let currentHost, !sources.contains(where: { $0.host == currentHost }) { self.currentHost = nil }
        // 聊天只有 Spaces(#501):每台主機的即時更新都訂閱版面事件(#40)。
        for source in sources { source.list.subscribesToLayout = true }
    }

    /// 合併後依「需要你／工作中／閒置」分組、套用搜尋的列表。
    public var sections: [AgentSection] {
        AgentListProjection.sections(sources: filteredProjectionSources, query: query, visible: visibleChats)
    }

    /// 套用主機篩選後的來源。
    private var filteredProjectionSources: [AgentListProjection.Source] {
        guard let currentHost else { return projectionSources }
        return projectionSources.filter { $0.host == currentHost }
    }

    private var projectionSources: [AgentListProjection.Source] { sources.map(projectionSource(of:)) }

    /// 剛關閉的 Tab 先從快照拿掉(連同它的 pane、Agent 與版面),不等重讀列表追上。
    private static func withoutRecentlyClosedTabs(_ snapshot: HostSnapshot, actions: WorkspaceActionsModel) -> HostSnapshot {
        let closed = Set(snapshot.tabs.map(\.id).filter { actions.isRecentlyClosed(tabID: $0) })
        guard !closed.isEmpty else { return snapshot }
        var trimmed = snapshot
        let closedPanes = Set(snapshot.panes.filter { closed.contains($0.tabID) }.map(\.id))
        trimmed.tabs.removeAll { closed.contains($0.id) }
        trimmed.panes.removeAll { closed.contains($0.tabID) }
        trimmed.agents.removeAll { agent in agent.tabID.map(closed.contains) ?? closedPanes.contains(agent.paneID) }
        trimmed.layouts = trimmed.layouts?.filter { !closed.contains($0.tabID) }
        return trimmed
    }

    package func projectionSource(of source: Source) -> AgentListProjection.Source {
        var projection = AgentListProjection.Source(
            host: source.host, label: source.host == selected ? nil : HostLabel(name: source.name, icon: source.icon),
            name: source.name, icon: source.icon, snapshot: source.list.snapshot.map { Self.withoutRecentlyClosedTabs($0, actions: source.actions) },
            previews: source.list.previews, preferences: source.actions.preferences)
        for (route, count) in awayTurnCounts where route.host == source.host {
            let session = source.list.snapshot?.agents.first { $0.paneID == route.paneID }?.sessionID
            if let session, source.actions.preferences.opened[session] == count.openedAt { projection.awayTurns[route.paneID] = count.turns }
        }
        return projection
    }

    /// 下一個「開啟紀錄跨過離開期間門檻」的時刻(沒有時 `nil`):畫面在那一刻重算,徽章不必等下一次無關的更新(#583)。
    public func nextAwayTransition(after now: Date) -> Date? {
        sources.compactMap { source in
            source.actions.preferences.opened.values
                .map { $0.addingTimeInterval(AwaySummary.threshold) }
                .filter { $0 > now }.min()
        }.min()
    }

    /// 一次投影的結果(#583):Spaces 段落、需要你段落與「離開期間」的列共用。
    private struct Projection {
        var spaces: [SpacesSection]
        var needsYou: NeedsYouSection?
        var away: [ChatRoute]
    }

    private struct ProjectionKey: Equatable {
        var sources: [AgentListProjection.Source]
        var selected: HostSelection
        var currentHost: HostSelection?
        var query: String
        var visible: Set<ChatRoute>
        var order: [ChatRoute]
        var justNow: ChatRoute?
    }

    @ObservationIgnored private var projectionCache: (key: ProjectionKey, value: Projection)?
    /// 實際投影(重算)的次數;測試以它確認「一次 body 只投影一次、輸入沒變不重算」。
    @ObservationIgnored package private(set) var projectionCount = 0
    /// 基礎投影(所有主機的 Spaces 段落)實際計算的次數;有主機篩選時一次重算也只算一次(#583)。
    @ObservationIgnored package private(set) var basePassCount = 0

    /// 以輸入(各主機的快照、預覽、偏好、搜尋、目前主機、需要你順序…)比對的投影快取:輸入沒變直接回上次結果。
    /// 讀輸入仍會登記觀察,所以來源變了畫面照常更新。
    private var projection: Projection {
        let all = projectionSources
        let key = ProjectionKey(
            sources: all, selected: selected, currentHost: currentHost, query: query, visible: visibleChats,
            order: needsYou.others.map(\.route), justNow: needsYou.latest?.route)
        if let cache = projectionCache, cache.key == key { return cache.value }
        projectionCount += 1
        let filtered = currentHost.map { host in all.filter { $0.host == host } } ?? all
        // 基礎投影只算一次:Spaces(依主機篩選)與「需要你」(所有主機)各自在它上面過濾(#583)。
        basePassCount += 1
        let base = AgentListProjection.allSpacesSections(sources: all, visible: key.visible)
        let spaces = AgentListProjection.filter(currentHost.map { host in base.filter { $0.host == host } } ?? base, query: query)
        let needsYouTabs = (currentHost == nil ? spaces : AgentListProjection.filter(base, query: query)).flatMap(\.tabs)
        let away = filtered.flatMap { source in
            (source.snapshot?.agents ?? []).filter { ChatUnread.State(agent: $0, source: source, visible: key.visible).isAway }
                .map { ChatRoute(host: source.host, paneID: $0.paneID) }
        }
        let value = Projection(
            spaces: spaces, needsYou: AgentListProjection.needsYouSection(tabs: needsYouTabs, order: key.order, justNow: key.justNow),
            away: away)
        projectionCache = (key, value)
        return value
    }

    /// Spaces(#275、#501 起聊天唯一的呈現):每個「主機 · workspace」一段，段內每個 Tab 一列;套用目前主機與搜尋(主機、workspace、Tab 名稱,#391)。
    public var spacesSections: [SpacesSection] { projection.spaces }

    /// 列表最上面的「需要你」段落(#531):所有主機(不受主機篩選)需要你的聊天、套用搜尋;
    /// 排序與「剛剛」來自 `needsYou`(沒有人驅動它時照列表順序、沒有「剛剛」)。沒有時 `nil`。
    public var needsYouSection: NeedsYouSection? { projection.needsYou }

    /// 有「離開期間」徽章的聊天(套用目前主機);變動時才重算輪數(#308)。
    public var awayRoutes: [ChatRoute] { projection.away }

    /// 任何一台主機有 Agent(不看搜尋)。沒有時不顯示搜尋欄。
    public var hasAgents: Bool { sources.contains { $0.list.hasAgents } }

    /// 讀不到的主機(保留它最後的列)。
    public var failures: [HostFailure] {
        sources.compactMap { source in
            guard currentHost == nil || source.host == currentHost, case .failed(let message) = source.list.phase else { return nil }
            return HostFailure(host: source.host, name: source.name, message: message)
        }
    }

    /// 裝置有沒有網路(網路路徑監看提供;沒有時不等連線逾時就顯示離線)。
    public var isNetworkAvailable = true

    /// 連線多久沒有結果就顯示「仍在連線」與再試一次。
    public static let slowConnectionThreshold: TimeInterval = ConnectingDisplayPolicy.slowThreshold

    /// 還在連線的主機，各一行狀態(依主機順序)。
    public func hostStatuses(at now: Date) -> [HostLoadStatus] {
        sources.compactMap { source in
            // 沒網路時連不上是確定的：列表只顯示離線，不逐台顯示連線中。
            guard isNetworkAvailable, currentHost == nil || source.host == currentHost, source.list.phase == .loading else { return nil }
            let elapsed = now.timeIntervalSince(source.list.updates.connectingSince)
            let state: HostLoadStatus.State
            switch ConnectingDisplayPolicy.display(elapsed: elapsed, isQuietReconnect: source.list.updates.isQuietReconnect) {
            case .hidden: return nil
            case .connecting: state = .connecting
            case .stillConnecting: state = .stillConnecting
            }
            return HostLoadStatus(host: source.host, name: source.name, icon: source.icon, state: state)
        }
    }

    /// 任何一台主機有 Agent 以外的 pane(終端機;Spaces 的 Tab 列看得到)。
    private var hasTerminals: Bool {
        sources.contains { $0.list.snapshot?.terminalPanes.isEmpty == false }
    }

    public var content: Content {
        if isAwaitingFirstHost { return .noHosts }
        if hasAgents { return .list }
        if !isNetworkAvailable { return .offline }
        if let message = allFailedMessage { return .failed(message) }
        if sources.contains(where: { $0.list.phase == .loading }) { return .loading }
        // 有主機讀不到時留在列表，錯誤顯示在那台主機的一行(#221),不換成「沒有 Agent」說明。
        if !failures.isEmpty { return .list }
        if hasTerminals { return .list }
        return .empty
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

    /// 視窗指令(選單列與快捷鍵)要的、選取中聊天的資料(#581)。
    package struct WindowTarget: Equatable {
        /// 「在新視窗開啟」的內容;沒選或列表上找不到是 `nil`。
        package var opening: SpacesTab.WindowOpening?
        /// 選取的是對話(不是 Pane 終端機);沒選是 `false`。
        package var hasConversation: Bool
    }

    /// 只查選取的那個聊天(所在那台主機的 snapshot),不對所有主機做完整 Spaces 投影(#581)。
    /// 沒選聊天(`route` 為 `nil`)時完全不讀列表資料。
    package func windowTarget(for route: ChatRoute?) -> WindowTarget {
        guard let route else { return WindowTarget(opening: nil, hasConversation: false) }
        guard let source = sources.first(where: { $0.host == route.host }) else { return WindowTarget(opening: nil, hasConversation: true) }
        let hasConversation = terminalTitle(of: route) == nil
        let tabs = AgentListProjection.spacesSections(sources: [projectionSource(of: source)], visible: [], query: "").flatMap(\.tabs)
        let opening = tabs.lazy.compactMap(\.newWindowOpening).first { $0.paneID == route.paneID }
        return WindowTarget(opening: opening, hasConversation: hasConversation)
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

    /// 回前景重撥(#550):連線已被丟棄,每台主機跳過退避立刻重連;手上有快照的列表照舊顯示,
    /// 「連線中」前 `ConnectingDisplayPolicy.quietGrace` 秒不出現(連上後無聲更新)。
    public func reconnectAfterForeground() {
        for source in sources { source.list.updates.beginQuietReconnect() }
        retryNow()
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
