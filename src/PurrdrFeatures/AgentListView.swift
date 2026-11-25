import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 聊天 tab 頂列的動作(#499):由 `TopNavigationView` 提供,列表本身不知道有哪些 sheet。
package struct ChatTopBarActions {
    var newChat: () -> Void
    /// Workspace 標題選單的「在此新增聊天」(#537):參數是主機與 Workspace id。
    var newChatInWorkspace: (HostSelection, String) -> Void
    /// 這台主機有沒有「在此新增聊天」(HTTPS 主機服務還沒有 tab.create)。
    var canNewChatInWorkspace: (HostSelection) -> Bool
    var addHost: () -> Void
    /// 寬視窗時頭像在對話欄工具列(`AccountButtonPlacement`),列表頂列沒有。
    var account: AnyView?

    package init(
        newChat: @escaping () -> Void, newChatInWorkspace: @escaping (HostSelection, String) -> Void,
        canNewChatInWorkspace: @escaping (HostSelection) -> Bool, addHost: @escaping () -> Void, account: AnyView?
    ) {
        self.newChat = newChat
        self.newChatInWorkspace = newChatInWorkspace
        self.canNewChatInWorkspace = canNewChatInWorkspace
        self.addHost = addHost
        self.account = account
    }
}

/// Agent 列表:聊天 tab 只有 Spaces 一種呈現(#501)——依「主機 · Workspace」分組、每個 Tab 一列。
///
/// 所有主機合併在同一個列表(#39):每段標題帶主機名;某台主機連不上時保留它最後的列，
/// 列表下方顯示「主機名：原因」。每台主機都讀不到、也沒有任何列時，選取中主機的錯誤才佔滿畫面。
/// 不整頁轉圈(#221):還在連的主機在列表上方各一行「連線中」(超過 10 秒「仍在連線」與再試一次);
/// 第一次載入還沒有列時是列表骨架;裝置沒網路時直接顯示離線。
///
/// 畫面可見且 app 在前景時才即時更新(長駐的訂閱通道在背景是 iOS 第一個殺的，行為規格 §3.7)。
/// app 在前景時，新的「需要你」只出現在列表裡，這個畫面不發任何系統通知。
public struct AgentListView: View {
    @Bindable var model: MergedAgentListModel
    @State private var presentation = WorkspacePresentation()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var listSizeClass
    /// 建立某台主機上某個 Agent 的對話 model(列表看到的 session)。由 composition root 提供。
    private let makeConversation: @MainActor (ChatRoute, String?) -> ConversationModel
    /// 建立某台主機上某個 Pane 的終端機 model(標題)。由 composition root 提供。
    private let makeTerminal: (@MainActor (ChatRoute, String) -> PaneTerminalModel)?
    /// 列表顯示時預先把前幾個聊天的快取讀進記憶體層,點進去時第一幀就有內容。
    private let prefetchConversations: (@MainActor ([ChatRoute]) async -> Void)?
    /// 所在視窗的導覽狀態(#31)。有的話：列是 split view 的選取(對話顯示在對話欄)、套用側欄的 workspace 篩選;
    /// 沒有的話列表自己推入對話。
    private let window: TopNavigationModel?
    /// 路徑上聊天目的地的畫面(窄視窗的堆疊給;寬視窗聊天顯示在對話欄,不給)。
    private let chatDestination: (ChatRoute) -> AnyView
    /// 把 Agent 對話或終端機開在新視窗(支援多視窗時才有)。
    private let openInNewWindow: ((PaneWindow.Kind, ChatRoute, String) -> Void)?
    /// 共用頂列的動作(#499):新增聊天、新增主機與帳號鈕。
    private let topBarActions: ChatTopBarActions
    @FocusState private var searchFocused: Bool
    /// 主機連線狀態行用的現在時間(有主機在連線時每秒更新，換成「仍在連線」)。
    @State private var now = Date()

    package init(
        model: MergedAgentListModel, window: TopNavigationModel? = nil,
        openInNewWindow: ((_ kind: PaneWindow.Kind, _ route: ChatRoute, _ title: String) -> Void)? = nil,
        topBar: ChatTopBarActions,
        chatDestination: @escaping (ChatRoute) -> AnyView = { _ in AnyView(EmptyView()) },
        prefetchConversations: (@MainActor ([ChatRoute]) async -> Void)? = nil,
        conversation: @escaping @MainActor (_ route: ChatRoute, _ sessionID: String?) -> ConversationModel,
        terminal: (@MainActor (_ route: ChatRoute, _ title: String) -> PaneTerminalModel)? = nil
    ) {
        self.model = model
        self.makeConversation = conversation
        self.makeTerminal = terminal
        self.prefetchConversations = prefetchConversations
        self.window = window
        self.openInNewWindow = openInNewWindow
        self.topBarActions = topBar
        self.chatDestination = chatDestination
    }

    private static let prefetchCount = 8

    /// 即時更新在前景時執行;主機新增、刪除或編輯後重來。
    private struct RunKey: Equatable {
        var active: Bool
        var lists: [ObjectIdentifier]
    }

    /// 放在呼叫端的 `NavigationStack` 或 `NavigationSplitView` 的列表欄裡(導覽層與工具列見 `TopNavigationView`)。
    public var body: some View {
        Group {
            if let window {
                content
                    // 版面圖選的 Agent、點了的推播通知、新開始的對話：交給視窗的選取，在對話欄打開。
                    .onChange(of: model.openedChat, initial: true) { _, route in
                        guard let route else { return }
                        model.openedChat = nil
                        window.selectedChat = route
                    }
                    // 對話欄打開與換掉的聊天各記一次開啟時間;開在旁邊的不算未讀(行為規格 F2.6)。
                    .onChange(of: window.selectedChat, initial: true) { old, new in
                        window.reportVisibleChat(new, to: model)
                    }
            } else {
                content
                    .navigationDestination(for: ChatRoute.self) { route in
                        conversationScreen(route)
                    }
                    .navigationDestination(item: $model.openedChat) { route in
                        conversationScreen(route)
                    }
            }
        }
        // 共用頂列(#499):左側大標題「聊天」,右側 [電腦圖示｜＋] 膠囊與頭像;往下滑時收合,搜尋欄貼頂。
        // 搜尋範圍是目前主機(所有主機就搜全部),比對 Tab、Workspace、主機(含 Tab 裡的 Agent 標題)。
        // 共用頁面(`topBarPage`):頁面底色、iPad 內容寬度上限、導覽標題(返回鈕用,導覽列隱藏)與頂列。
        .topBarPage(topBarContent)
        // 「You should know」:每台主機各自輪詢(列表可見且在前景時，#23)。
        .task(id: RunKey(active: scenePhase == .active, lists: model.runKey)) {
            guard scenePhase == .active else { return }
            await model.runNotes()
        }
        // 有主機在連線時每秒更新現在時間，連線狀態行到 10 秒換成「仍在連線」(#221)。
        // 只在前景跑，過了門檻(「仍在連線」)就停(#492)。
        .task(id: ConnectingClockKey(active: scenePhase == .active, needsTicks: needsConnectingTicks)) {
            await ConnectingClock.run(
                isActive: scenePhase == .active, needsTicks: { needsConnectingTicks }, tick: { now = $0 }, sleep: Sleeping.task)
        }
        // 預先載入前幾個聊天的快取(列表順序變了才重做;已在記憶體的不會再讀 SQLite)。
        // 「離開期間」徽章的輪數(#308):有徽章的列變動時才算(每個聊天、每個開啟時間只算一次)。
        .task(id: model.awayRoutes) {
            await model.refreshAwayTurns()
        }
        .task(id: RunKey(active: scenePhase == .active, lists: model.runKey)) {
            guard scenePhase == .active else { return }
            // 同一份列表開在好幾個視窗時，每台主機的即時更新各只跑一份(`AgentListModel.liveUpdates`,#31)。
            await model.run()
        }
    }

    private var topBarContent: TopBarContent {
        let filtered = model.currentHost.flatMap { model.hostLabel(of: $0) }
        return TopBarContent(
            tab: .chats, title: "Chats",
            hostScope: TopBarHostScope(filteredHostName: filtered?.name),
            hostMenu: AnyView(CurrentHostMenu(list: model, addHost: topBarActions.addHost)),
            plus: AnyView(TopBarPlusButton(title: "New Chat", identifier: "toolbar.newChat", action: topBarActions.newChat)),
            account: topBarActions.account,
            search: TopBarContent.Search(text: $model.query, focus: $searchFocused, identifier: "agentList.search", prompt: "Search Tabs, Workspaces, Hosts"))
    }

    /// 搜尋了但沒有任何符合(顯示「找不到」,連線錯誤區塊先收起,免得疊在說明上)。
    private func searchHasNoMatch(_ sections: [SpacesSection]) -> Bool {
        guard !model.query.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return sections.isEmpty
    }

    private var needsConnectingTicks: Bool { ConnectingClock.needsTicks(for: model.hostStatuses(at: now)) }

    private struct ConnectingClockKey: Equatable {
        var active: Bool
        var needsTicks: Bool
    }

    private var selection: Binding<ChatRoute?> {
        Binding { window?.selectedChat } set: { window?.selectedChat = $0 }
    }

    /// Agent 的 pane 開對話;agent 以外的 pane(終端機列、版面圖的終端機方塊)開它的 Pane 終端機(#37 故事 14)。
    @ViewBuilder
    private func conversationScreen(_ route: ChatRoute) -> some View {
        if let title = model.terminalTitle(of: route), let makeTerminal {
            PaneTerminalScreen(model: makeTerminal(route, title))
        } else {
            ConversationScreen(
                model: makeConversation(route, model.sessionID(of: route)),
                makeTerminal: makeTerminal.map { make in
                    { @MainActor paneID, title in make(ChatRoute(host: route.host, paneID: paneID), title) }
                },
                layoutSnapshot: { [model] in model.snapshot(for: route.host) },
                openLayoutTarget: { [model] target in
                    switch target {
                    case .chat(let paneID), .terminal(let paneID): model.openedChat = ChatRoute(host: route.host, paneID: paneID)
                    }
                })
            .environment(\.usageHost, route.host)
            // 進入與離開對話各記一次開啟時間;開著時不算未讀(行為規格 F2.6)。
            .onAppear { model.chatAppeared(route) }
            .onDisappear { model.chatDisappeared(route) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .loading:
            loadingList
        case .noHosts:
            // 還沒有任何主機(#332):說明加主要按鈕(系統 glass prominent),次要是試用 Demo。
            ContentUnavailableView {
                Label("No Hosts Yet", systemImage: "desktopcomputer")
            } description: {
                Text("Add the host where your agents run, and they show up here. Or look around with sample conversations first.")
            } actions: {
                if let window {
                    Button("Add Host") { window.openAddHost() }
                        .filledProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .accessibilityIdentifier("agentList.addHost")
                }
                Button("Try the Demo") { model.enterDemo?() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("agentList.tryDemo")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agentList.noHosts")
        case .offline:
            // 沒網路就直接說，不等連線逾時(#221);網路恢復後自動重連。
            ContentUnavailableView {
                Label("No Internet Connection", systemImage: "wifi.slash")
            } description: {
                Text("Connect to Wi-Fi or cellular data to see your agents. Purrdr reconnects automatically.")
            } actions: {
                Button("Try Again") { model.retry() }
                    .accessibilityIdentifier("agentList.retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agentList.offline")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Load Agents", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
                    .accessibilityIdentifier("agentList.retry")
            }
        case .empty:
            ContentUnavailableView(
                "No Agents",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Agents you start in herdr on your hosts appear here.")
            )
        case .list:
            list
        }
    }

    /// 第一次載入、還沒有任何列：大標題、各主機的連線狀態與列表骨架(不整頁轉圈,#221)。
    private var loadingList: some View {
        List {
            hostStatusRows
            // 列數取上次列表的列數(#496);整區是一個「載入中」元素,VoiceOver 不逐列念。
            Section {
                VStack(spacing: 20) {
                    ForEach(0..<model.loadingRowCount, id: \.self) { index in
                        ChatRowView(content: .placeholder(index))
                    }
                }
                .skeleton(identifier: "agentList.loading.skeleton")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .appGroupedList()
        #endif
        .accessibilityIdentifier("agentList.loading")
    }

    /// 裝置離線(已有列時)與還在連線的主機：放在大標題下面，一眼看到哪台在連(#221)。
    @ViewBuilder
    private var hostStatusRows: some View {
        if !model.isNetworkAvailable {
            Section {
                Label("No internet connection. Showing agents from your last connection.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("agentList.offlineBanner")
            }
        }
        let statuses = model.hostStatuses(at: now)
        if !statuses.isEmpty {
            Section {
                ForEach(statuses, id: \.host) { status in
                    HostLoadStatusRow(status: status) { model.retry() }
                }
            }
        }
    }

    private var list: some View {
        // 這一次繪製只投影一次(投影要走過所有主機的 snapshot);列、搜尋無結果與預讀都用同一份。
        let sections = model.spacesSections
        let prefetchRoutes = AgentListProjection.prefetchRoutes(from: sections, limit: Self.prefetchCount)
        return Group {
            // split view 的內容欄：列是選取(持續高亮，HIG 20.9);獨立的 NavigationStack 裡則是推入。
            // 寬視窗(split view 的內容欄)的列是選取;窄視窗的堆疊是推入,List 不能有 selection
            // (NavigationLink 在有 selection 的 List 裡,push 後第一下返回會被吃掉,#641 查出的根因)。
            if window != nil && listSizeClass != .compact {
                List(selection: selection) {
                    hostStatusRows
                    listRows(sections)
                }
                .environment(\.selectedChatRoute, window?.selectedChat)
            } else {
                List {
                    hostStatusRows
                    listRows(sections)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .appGroupedList()
        #endif
        .environment(\.pushesChatsByPath, window != nil && listSizeClass == .compact)
        // 記住列數,下次冷啟動的載入骨架照這個數量(#496)。
        .onAppear { model.rememberRowCount(of: sections) }
        .onChange(of: MergedAgentListModel.rowCount(of: sections)) { model.rememberRowCount(of: sections) }
        // 預先載入畫面上前幾列聊天的快取(列表順序變了才重做;已在記憶體的不會再讀 SQLite)。
        .task(id: prefetchRoutes) { await prefetchConversations?(prefetchRoutes) }
        .overlay {
            if searchHasNoMatch(sections) {
                ContentUnavailableView.search(text: model.query)
                    .accessibilityIdentifier("agentList.noMatches")
            }
        }
        // 版面圖選的 Pane:聊天推入對話(或在對話欄打開);Pane 終端機畫面還沒有(Pane 終端機那張票接上)。
        .workspaceActionsPresentation(
            actions: { model.actions(for: $0) }, snapshot: { model.snapshot(for: $0) }, presentation: presentation,
            path: Binding { window?.chatsPath ?? [] } set: { window?.chatsPath = $0 },
            chatDestination: chatDestination) { host, target in
            // 版面圖選的 Pane:Agent 開對話，終端機方塊開它的 Pane 終端機(兩者都以 pane 指定，見 `conversationScreen`)。
            switch target {
            case .chat(let paneID), .terminal(let paneID): model.openedChat = ChatRoute(host: host, paneID: paneID)
            }
        }
        // Command-F(#31):視窗的導覽狀態要求搜尋欄取得焦點(#391)。
        .onChange(of: window?.isSearchFocused ?? false) { _, focused in
            guard focused else { return }
            searchFocused = true
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused { window?.isSearchFocused = false }
        }
    }

    @ViewBuilder
    private func listRows(_ sections: [SpacesSection]) -> some View {
        let failures = model.failures
        SpacesSectionsContent(
            needsYou: model.needsYouSection, sections: sections, model: model, presentation: presentation, openInNewWindow: openInNewWindow,
            newChatInWorkspace: topBarActions.newChatInWorkspace, canNewChatInWorkspace: topBarActions.canNewChatInWorkspace)
        if let filtered = model.currentHost.flatMap({ model.hostLabel(of: $0) }),
           model.query.trimmingCharacters(in: .whitespaces).isEmpty,
           sections.isEmpty {
            // 篩選的主機沒有東西：留在列表裡說明，篩選鈕仍在左上角可改回所有主機。
            // 系統空狀態(ContentUnavailableView)放在列裡,與下面的「連線中斷」區塊同時出現時也不疊在一起。
            Section {
                ContentUnavailableView(
                    "No Agents", systemImage: "bubble.left.and.bubble.right",
                    description: Text("No agents on \(filtered.name)."))
                    .accessibilityIdentifier("agentList.filterEmpty")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        if !failures.isEmpty, !searchHasNoMatch(sections) {
            // 讀不到的主機：列已經在畫面上時，錯誤放在列下方，不把列推走(行為規格 F2.9)。不用 alert,也不自動消失:
            // 重新連上才會消失;列保持最後一次讀到的樣子(HIG 20.5)。每台主機一行「主機名：原因」(#37 故事 3)。
            Section {
                ForEach(failures, id: \.host) { failure in
                    Label(failure.text, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("agentList.error.\(failure.host.storedValue)")
                }
                Button("Try Again", systemImage: "arrow.clockwise") { model.retry() }
                    .font(.footnote)
                    .accessibilityIdentifier("agentList.retry")
            } header: {
                Text("Connection Lost")
            }
        }
    }

    /// 某台主機讀不到(Claude 方案用量只在選取中主機讀得到時顯示)。
    private func list(failedFor host: HostSelection) -> Bool {
        if case .failed? = model.list(for: host)?.phase { return true }
        return false
    }
}

/// 持有對話 model 的容器:navigationDestination 的內容可能被重建，model 只在第一次建立。
///
/// `window` 有值時(split view 的對話欄)，終端機推入與否也記在視窗的導覽狀態(Command-Shift-T 也能打開);
/// `route` 是這個聊天(用來比對視窗要開的終端機)。
struct ConversationScreen: View {
    @State private var model: ConversationModel
    /// 同一台主機上某個 Pane 的終端機 model(pane id、標題)。
    let makeTerminal: (@MainActor (String, String) -> PaneTerminalModel)?
    let window: TopNavigationModel?
    let route: ChatRoute?
    @State private var terminal: PaneTerminalModel?
    /// 推入中的變更頁(#310)。
    @State private var changes: ChangesModel?
    /// 更多選單的「顯示版面」(#381):讀聊天所在主機的 snapshot(開啟當下，不即時更新);沒有時不顯示這一項。
    let layoutSnapshot: (@MainActor () -> HostSnapshot?)?
    /// 版面圖選了 Pane 之後的動作(開那個 Pane)。
    let openLayoutTarget: (@MainActor (PaneOpenTarget) -> Void)?
    @State private var showsLayout = false
    @State private var pendingLayoutTarget: PaneOpenTarget?
    /// 用量環與面板(#513、#617):這個聊天的 Agent 在這台主機的方案用量(沒有來源時是 `nil`)。
    @Environment(\.usageSections) private var usageContext
    @Environment(\.usageHost) private var usageHost
    @Environment(\.scenePhase) private var scenePhase
    @State private var usageSection: UsageSectionModel?
    @State private var showsUsage = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 「⋯」選單開的 sheet(#515):權限模式、做完再送、待辦、背景子 Agent;模型與思考深度另用 `isChoosingModel`(同輸入框的模型膠囊)。
    @State private var menuSheet: ConversationMenuSheetKind?
    @State private var isChoosingModel = false

    init(
        model: @autoclosure () -> ConversationModel, makeTerminal: (@MainActor (String, String) -> PaneTerminalModel)?,
        window: TopNavigationModel? = nil, route: ChatRoute? = nil,
        layoutSnapshot: (@MainActor () -> HostSnapshot?)? = nil, openLayoutTarget: (@MainActor (PaneOpenTarget) -> Void)? = nil
    ) {
        self.layoutSnapshot = layoutSnapshot
        self.openLayoutTarget = openLayoutTarget
        _model = State(wrappedValue: model())
        self.makeTerminal = makeTerminal
        self.window = window
        self.route = route
    }

    var body: some View {
        ConversationView(model: model)
            .hidesTabBarWhenCompact()
            .toolbar {
                // 右上角一顆玻璃膠囊 [用量環｜⋯](#513,同一個 ToolbarItemGroup 由系統合成):「⋯」是 Pane 終端機、Git 變更、顯示版面(#381)。
                ToolbarItemGroup(placement: .primaryAction) {
                    UsageRingButton(
                        summary: usageSummary, showsPopover: panelBinding(compact: false), tap: { showsUsage = true },
                        model: model, usageSection: usageSection, display: usageContext?.display.display ?? .used)
                    ConversationMoreMenu(
                        model: model, usageSummary: usageSummary, canOpenTerminal: makeTerminal != nil,
                        canShowLayout: layoutSnapshot != nil, select: selectMenuItem)
                }
            }
            .task(id: UsageLifecycleKey(active: scenePhase == .active, agentKind: model.agentKind)) { startUsage() }
            .onChange(of: model.modelName) { _, name in usageSection?.activeGroup = name.flatMap(PlanUsage.Group.init(modelName:)) }
            .conversationPanelSheet(
                isPresented: panelBinding(compact: true), model: model, usageSection: usageSection,
                display: usageContext?.display.display ?? .used)
            .onChange(of: window?.conversationPanelToggleCount) { showsUsage.toggle() }
            .sheet(item: $menuSheet) { ConversationMenuSheet(kind: $0, model: model) }
            .sheet(isPresented: $isChoosingModel, onDismiss: { Task { await model.finishChoosingModel() } }) {
                ModelSheet(model: model)
            }
            // 工作中膠囊的子 Agent 數被點了:開背景子 Agent sheet。
            .onChange(of: model.showsBackgroundAgentsSheet) { _, shown in
                guard shown else { return }
                model.showsBackgroundAgentsSheet = false
                menuSheet = .backgroundAgents
            }
            .task(id: model.canOpenChanges) { await model.refreshGitMenu() }
            // 顯示版面是下一頁(#619):從聊天再往下一層,左上「<」回聊天。
            .navigationDestination(isPresented: $showsLayout) {
                if let workspaceID = model.workspaceID, let snapshot = layoutSnapshot?() {
                    let label = snapshot.workspaces.first { $0.id == workspaceID }?.label ?? workspaceID
                    SpacesLayoutPage(
                        workspaceLabel: label, layout: SpacesLayout(snapshot: snapshot, workspaceID: workspaceID),
                        onChoose: { pendingLayoutTarget = $0 })
                }
            }
            .onChange(of: showsLayout) { _, shown in
                // 返回聊天之後才開選到的 Pane(不能在返回的同一刻 push)。
                guard !shown, let target = pendingLayoutTarget else { return }
                pendingLayoutTarget = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    openLayoutTarget?(target)
                }
            }
            .navigationDestination(isPresented: Binding(get: { changes != nil }, set: { if !$0 { changes = nil } })) {
                if let changes {
                    ChangesView(model: changes) { message in
                        // 先回到聊天再送：撤回倒數與機密偵測的確認都在聊天畫面。
                        self.changes = nil
                        Task { await model.sendReview(message) }
                    }
                }
            }
            .onChange(of: window?.openedTerminal, initial: true) { _, opened in
                if let route, opened == route, terminal == nil { openTerminal() }
            }
            #if canImport(UIKit)
            .navigationDestination(isPresented: Binding(
                get: { terminal != nil },
                set: {
                    guard !$0 else { return }
                    terminal = nil
                    if let route, window?.openedTerminal == route { window?.openedTerminal = nil }
                }
            )) {
                if let terminal { PaneTerminalView(model: terminal).hidesTabBarWhenCompact() }
            }
            #endif
    }

    private struct UsageLifecycleKey: Hashable {
        var active: Bool
        var agentKind: String?
    }

    /// 聊天面板的開關(#617):compact 是 sheet、regular 是 popover,只有符合目前 size class 的那個開。
    private func panelBinding(compact: Bool) -> Binding<Bool> {
        Binding(
            get: { showsUsage && (horizontalSizeClass == .compact) == compact },
            set: { showsUsage = $0 })
    }

    /// 頂列用量環的內容:context 與這台主機的方案用量取最高的一項。
    private var usageSummary: UsageSummary? {
        UsageSummary.make(
            contextUsed: model.displayProgress.contextPercent,
            planRows: usageSection?.entries.filter { $0.state == .rows }.flatMap(\.rows) ?? [],
            display: usageContext?.display.display ?? .used)
    }

    /// 聊天在畫面上才查方案用量,離開或進背景就停(沒有來源的 Agent 種類不查)。
    private func startUsage() {
        guard scenePhase == .active else {
            usageSection?.disappeared()
            return
        }
        if usageSection == nil, let usageContext, let usageHost, let agent = PlanUsageAgent(agentKind: model.agentKind) {
            let section = usageContext.section(usageHost, [agent], false)
            section.activeGroup = model.modelName.flatMap(PlanUsage.Group.init(modelName:))
            // 這台主機沒有啟用這個 Agent 的用量(#477):當作沒有來源。
            if !section.agents.isEmpty { usageSection = section }
        }
        usageSection?.appeared()
    }

    /// 點「⋯」選單的項目:開各自的 sheet 或畫面。
    private func selectMenuItem(_ item: ConversationMoreMenuPlan.Item) {
        switch item {
        case .usage: showsUsage = true    // 開面板(從用量環展開)
        case .permissionMode: menuSheet = .permissionMode
        case .model:
            isChoosingModel = true
            Task { await model.beginChoosingModel() }
        case .sendWhenDone: menuSheet = .sendWhenDone
        case .todos: menuSheet = .todos
        case .backgroundAgents: menuSheet = .backgroundAgents
        case .terminal: openTerminal()
        case .gitChanges: changes = model.makeChanges()
        case .layout: showsLayout = true
        }
    }

    private func openTerminal() {
        guard let makeTerminal, terminal == nil else { return }
        terminal = makeTerminal(model.paneID, model.title.isEmpty ? model.paneID : model.title)
        if let window, let route, window.openedTerminal != route { window.openedTerminal = route }
    }
}

/// 一台還在連線的主機(#221):主機圖示、名稱與「連線中…」(系統小型進度);超過 10 秒換成「仍在連線…」與「再試一次」。
struct HostLoadStatusRow: View {
    let status: HostLoadStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HostIconBadge(status.icon, diameter: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: status.name)
                Text(stateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agentList.host.\(status.host.storedValue)")
            Spacer(minLength: 8)
            switch status.state {
            case .connecting:
                ProgressView()
                    .accessibilityHidden(true)
            case .stillConnecting:
                Button("Try Again", action: retry)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("agentList.host.\(status.host.storedValue).retry")
            }
        }
    }

    private var stateText: LocalizedStringKey {
        switch status.state {
        case .connecting: "Connecting…"
        case .stillConnecting: "Still connecting…"
        }
    }
}

/// Agent 狀態同時用文字、符號形狀與顏色表示，不只靠顏色(DESIGN.md)。
/// 顏色只上在符號(`StatusTone`);文字用主要色或次要文字色，不上狀態色(#237)。
struct StatusLabel: View {
    let status: AgentStatus

    var body: some View {
        // 不用 `Label`:在 List 列裡 Label 套的是列表樣式(圖示固定欄寬、標題對齊列文字),放進 `fixedSize` 的右側欄
        // 算不出理想寬度，標題被擠成極窄、一字一行，整列被撐高(#35)。
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tone.style)
            Text(status.title)
                .foregroundStyle(status.textEmphasis.style)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// section 標題：組名 + 數量(#37 故事 18)。一般大小寫，不全大寫(HIG 20.2)。
struct AgentSectionHeader: View {
    let group: AgentGroup
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(group.title)
            // 不再疊一層 `.secondary`:section 標題本身已是次要色，再疊一次對比只剩約 2:1(#35)。
            Text(count, format: .number)
                .monospacedDigit()
        }
        .textCase(nil)
        .foregroundStyle(.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentList.section.\(group)")
    }
}

extension AgentGroup {
    var title: LocalizedStringKey {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs You"
        case .working: "Working"
        case .idle: "Idle"
        }
    }
}

extension AgentStatus {
    /// 「需要你」一律有 `!` 符號(DESIGN.md 顏色一節)。每個狀態的形狀都不同。
    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle.fill"
        // 實心圓 = 有未讀的回覆、空心圓 = 已讀(行為規格 F2.5;列表會把未讀折算成 done、已讀折算成 idle)。
        case .done: "circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

extension EnvironmentValues {
    /// 列以導覽路徑推入(窄視窗的 `NavigationStack(path:)`);`false` 時列是 split view 的選取。
    @Entry var pushesChatsByPath = false
    /// iPad split view 列表目前選取的聊天(`selectionFill(for:)` 用);獨立的 NavigationStack 沒有選取。
    @Entry var selectedChatRoute: ChatRoute?
}

extension View {
    /// iPad 選取列用中性灰底(`neutralSelection`),文字不換色(#238)。
    func selectionFill(for route: ChatRoute) -> some View {
        modifier(SelectionFillModifier(route: route))
    }
}

private struct SelectionFillModifier: ViewModifier {
    let route: ChatRoute
    @Environment(\.selectedChatRoute) private var selectedChatRoute

    // 不用 if/else 分支：選取切換時列的 identity 不變(滑動與選單狀態不重建)。
    func body(content: Content) -> some View {
        let isSelected = selectedChatRoute == route
        content
            .foregroundStyle(.primary)
            .listRowBackground(isSelected ? Rectangle().fill(.neutralSelection) : nil)
    }
}
