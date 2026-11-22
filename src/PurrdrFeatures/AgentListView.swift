import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// Agent 列表(DESIGN.md 方向 A):系統 grouped list,依「已釘選／需要你／工作中／閒置」分 section,標題帶數量。
///
/// 所有主機的 Agent 合併在同一個列表(#39):非選取中主機的列在副標開頭標示主機名;某台主機連不上時保留它最後的列，
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
    /// 建立某台主機上某個 Agent 的對話 model(列表看到的 session)。由 composition root 提供。
    private let makeConversation: @MainActor (ChatRoute, String?) -> ConversationModel
    /// 建立某台主機上某個 Pane 的終端機 model(標題)。由 composition root 提供。
    private let makeTerminal: (@MainActor (ChatRoute, String) -> PaneTerminalModel)?
    /// 所在視窗的導覽狀態(#31)。有的話：列是 split view 的選取(對話顯示在對話欄)、套用側欄的 workspace 篩選;
    /// 沒有的話列表自己推入對話。
    private let window: TopNavigationModel?
    /// 把 Agent 對話或終端機開在新視窗(支援多視窗時才有)。
    private let openInNewWindow: ((PaneWindow.Kind, AgentRow) -> Void)?
    @FocusState private var searchFocused: Bool
    /// 主機連線狀態行用的現在時間(有主機在連線時每秒更新，換成「仍在連線」)。
    @State private var now = Date()

    public init(
        model: MergedAgentListModel, window: TopNavigationModel? = nil,
        openInNewWindow: ((_ kind: PaneWindow.Kind, _ row: AgentRow) -> Void)? = nil,
        conversation: @escaping @MainActor (_ route: ChatRoute, _ sessionID: String?) -> ConversationModel,
        terminal: (@MainActor (_ route: ChatRoute, _ title: String) -> PaneTerminalModel)? = nil
    ) {
        self.model = model
        self.makeConversation = conversation
        self.makeTerminal = terminal
        self.window = window
        self.openInNewWindow = openInNewWindow
    }

    /// 即時更新在前景時執行;主機新增、刪除或編輯後重來。
    private struct RunKey: Equatable {
        var active: Bool
        var lists: [ObjectIdentifier]
    }

    /// 放在呼叫端的 `NavigationStack` 或 `NavigationSplitView` 的內容欄裡(導覽層與工具列見 `TopNavigationView`)。
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
                        if let old, old != new { model.chatDisappeared(old) }
                        if let new { model.chatAppeared(new) }
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
        // 沒有大標題、也沒有標題選單(#268):導覽列只有主機篩選、「⋯」與帳號，檢視切換只用列表第一列的分段控制。
        // 標題仍設定，給返回鈕與 VoiceOver 用，只是不畫在導覽列上。
        .navigationTitle(model.mode.title)
        .toolbar(removing: .title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 「You should know」:每台主機各自輪詢(列表可見且在前景時，#23)。
        .task(id: RunKey(active: scenePhase == .active, lists: model.runKey)) {
            guard scenePhase == .active else { return }
            await model.runNotes()
        }
        // 有主機在連線時每秒更新現在時間，連線狀態行到 10 秒換成「仍在連線」(#221)。
        .task(id: hasConnectingHosts) {
            while hasConnectingHosts, !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // 「離開期間」徽章的輪數(#308):有徽章的列變動時才算(每個聊天、每個開啟時間只算一次)。
        .task(id: model.agentRows.filter(\.isAway).map(\.id)) {
            await model.refreshAwayTurns()
        }
        .task(id: RunKey(active: scenePhase == .active, lists: model.runKey)) {
            guard scenePhase == .active else { return }
            // 同一份列表開在好幾個視窗時，每台主機的即時更新各只跑一份(`AgentListModel.liveUpdates`,#31)。
            await model.run()
        }
    }

    private var hasConnectingHosts: Bool { !model.hostStatuses(at: now).isEmpty }

    /// 套用側欄 workspace 篩選(選取中主機的 workspace)後的分組。
    private var sections: [AgentSection] {
        window?.visibleSections(model.sections, host: model.selected, snapshot: model.snapshot(for: model.selected)) ?? model.sections
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
            ConversationScreen(model: makeConversation(route, model.sessionID(of: route)), makeTerminal: makeTerminal.map { make in
                { @MainActor paneID, title in make(ChatRoute(host: route.host, paneID: paneID), title) }
            })
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
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .foregroundStyle(Color.primary)
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
        case .noAgentsInAgentsView:
            ContentUnavailableView {
                Label("No Agents", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("No workspace on your hosts is running an agent. Spaces also shows their terminals.")
            } actions: {
                Button("Show Spaces") { model.mode = .spaces }
                    .accessibilityIdentifier("agentList.showSpaces")
            }
        case .list:
            list
        }
    }

    /// 第一次載入、還沒有任何列：大標題、各主機的連線狀態與列表骨架(不整頁轉圈,#221)。
    private var loadingList: some View {
        List {
            modeRow
            hostStatusRows
            Section {
                ForEach(0..<3, id: \.self) { index in
                    AgentRowView(row: .placeholder(index), host: nil)
                }
            }
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .appGroupedList()
        #endif
        .contentMargins(.top, 0, for: .scrollContent)
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
        let sections = sections
        return Group {
            // split view 的內容欄：列是選取(持續高亮，HIG 20.9);獨立的 NavigationStack 裡則是推入。
            if window != nil {
                List(selection: selection) {
                    modeRow
                    hostStatusRows
                    listRows(sections)
                }
                .environment(\.selectedChatRoute, window?.selectedChat)
            } else {
                List {
                    modeRow
                    hostStatusRows
                    listRows(sections)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .appGroupedList()
        #endif
        .contentMargins(.top, 0, for: .scrollContent)
        // 換檢視就是另一份清單：重建 List,捲回最上面，不停在原本捲到的位置(#40)。
        .id(model.mode)
        .overlay {
            if (model.mode == .spaces ? spacesSections.isEmpty : sections.isEmpty), !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    "No Matching Agents",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different name, agent, folder, or host.")
                )
            }
        }
        // 版面圖選的 Pane:聊天推入對話(或在對話欄打開);Pane 終端機畫面還沒有(Pane 終端機那張票接上)。
        .workspaceActionsPresentation(actions: { model.actions(for: $0) }, presentation: presentation) { host, target in
            // 版面圖選的 Pane:Agent 開對話，終端機方塊開它的 Pane 終端機(兩者都以 pane 指定，見 `conversationScreen`)。
            switch target {
            case .chat(let paneID), .terminal(let paneID): model.openedChat = ChatRoute(host: host, paneID: paneID)
            }
        }
        // Command-F(#31):視窗的導覽狀態要求搜尋欄取得焦點(搜尋欄只在 Agents 檢視，要求時先換過去)。
        .onChange(of: window?.isSearchFocused ?? false) { _, focused in
            guard focused else { return }
            model.mode = .agents
            searchFocused = true
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused { window?.isSearchFocused = false }
        }
    }

    /// 列表最上面(#268;#313 改成攤開):Agents／Spaces 兩列勾選;Agents 檢視下方接著搜尋欄。
    /// 沒有大標題。Spaces 檢視沒有搜尋(切過去時清掉搜尋字，不留看不見的篩選)。
    @ViewBuilder
    private var modeRow: some View {
        Section {
            AgentListModeControl(mode: $model.mode)
        }
        #if os(iOS)
        // 貼著導覽列、跟下面的內容只隔一般間距(inset grouped 第一個 section 上方預設有一大段空白)。
        .listSectionSpacing(.compact)
        #endif
        .onChange(of: model.mode) { _, mode in
            if mode == .spaces { model.query = "" }
        }
        if model.mode == .agents {
            Section {
                AgentListSearchField(query: $model.query, focused: $searchFocused)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            #if os(iOS)
            .listSectionSpacing(.compact)
            #endif
        }
    }

    @ViewBuilder
    private func listRows(_ sections: [AgentSection]) -> some View {
        let failures = model.failures
        if model.mode == .spaces {
            SpacesSectionsContent(sections: spacesSections, model: model, presentation: presentation)
        } else if !sections.isEmpty {
            // 單一清單(#244):不分段，順序仍是已釘選、需要你、工作中、閒置。
            Section {
                ForEach(sections.flatMap(\.rows)) { row in agentRow(row) }
            }
        }
        if let filtered = model.currentHost.flatMap({ model.hostLabel(of: $0) }),
           model.query.trimmingCharacters(in: .whitespaces).isEmpty,
           model.mode == .spaces ? spacesSections.isEmpty : sections.isEmpty {
            // 篩選的主機沒有東西：留在列表裡說明，篩選鈕仍在左上角可改回所有主機。
            Section {
                Text("No agents on \(filtered.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("agentList.filterEmpty")
            }
        }
        if !failures.isEmpty {
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

    /// 一個 Agent 列(兩種檢視共用：同樣的滑動、選單、已讀與釘選;Spaces 檢視的版面不同)。
    private func agentRow(_ row: AgentRow) -> some View {
        NavigationLink(value: row.route) {
            AgentRowView(row: row, host: model.hostLabel(of: row.host))
        }
            .accessibilityIdentifier("agent.row.\(row.id)")
            .selectionFill(for: row.route)
            .workspaceRowActions(
                WorkspaceRowContext(paneID: row.paneID, snapshot: model.snapshot(for: row.host)), host: row.host,
                actions: model.actions(for: row.host), presentation: presentation, snapshot: model.snapshot(for: row.host),
                openInNewWindow: openInNewWindow.map { open in { kind in open(kind, row) } }
            )
    }

    /// Spaces 檢視：套用側欄的 workspace 篩選(選取中主機的那個 workspace)。
    private var spacesSections: [SpacesSection] {
        let all = model.spacesSections
        guard let filter = window?.workspaceFilter,
              let snapshot = model.snapshot(for: model.selected), snapshot.workspaces.contains(where: { $0.id == filter }) else { return all }
        return all.filter { $0.host == model.selected && $0.workspaceID == filter }
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

    init(
        model: @autoclosure () -> ConversationModel, makeTerminal: (@MainActor (String, String) -> PaneTerminalModel)?,
        window: TopNavigationModel? = nil, route: ChatRoute? = nil
    ) {
        _model = State(wrappedValue: model())
        self.makeTerminal = makeTerminal
        self.window = window
        self.route = route
    }

    var body: some View {
        ConversationView(model: model)
            .toolbar {
                if makeTerminal != nil {
                    // 標題列的終端機鈕：打開這個 Agent 自己的 Pane(#37 故事 43)。
                    ToolbarItem(placement: .primaryAction) {
                        PaneTerminalButton { openTerminal() }
                    }
                }
                // 變更鈕(#310):知道 Agent 的工作目錄、連線方式讀得了 git 才顯示。
                if model.canOpenChanges {
                    ToolbarItem(placement: .primaryAction) {
                        ChangesButton { changes = model.makeChanges() }
                    }
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
                if let terminal { PaneTerminalView(model: terminal) }
            }
            #endif
    }

    private func openTerminal() {
        guard let makeTerminal, terminal == nil else { return }
        terminal = makeTerminal(model.paneID, model.title.isEmpty ? model.paneID : model.title)
        if let window, let route, window.openedTerminal != route { window.openedTerminal = route }
    }
}

/// Agents 檢視的一列(#244 單一清單):列首是 agent 種類頭像、右下角是狀態(#316),第一行名稱與時間，第二行小主機圖示與「主機 · 最後一句」。
struct AgentRowView: View {
    let row: AgentRow
    /// 這列所在主機的名稱與圖示(選取中主機也有)。
    let host: HostLabel?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 次要色;iPad 選取列是中性灰底(`selectionFill(for:)`),選取中也不換色。
    private var secondary: AnyShapeStyle { AnyShapeStyle(.secondaryText) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentStatusAvatar(content: .agent(AgentKind(rawKind: row.kind)), status: row.status)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                previewLine
                    .font(.subheadline)
                    .lineLimit(lines(2))
                if dynamicTypeSize.isAccessibilitySize { trailingColumn }
            }
        }
        // 一句念完(#269,spec #267 故事 14):agent、workspace、狀態、主機 · 最後一句、時間;畫面的排列順序不同，不用 `.combine`。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.accessibilityText(row, host: host)))
        .accessibilityValue(row.isUnread ? Text("Unread") : Text(verbatim: ""))
    }

    /// VoiceOver 句子：agent 種類、workspace、狀態(與釘選、靜音)、「主機 · 最後一句」、時間，以「, 」連接。
    static func accessibilityText(_ row: AgentRow, host: HostLabel?) -> String {
        let hostName = host?.name ?? ""
        let preview: String = switch row.preview {
        case .needsInput: "\(hostName) · \(String(localized: "Waiting for your input"))"
        case .message(let text, let fromYou): fromYou ? "\(hostName) · \(String(localized: "You: \(text)"))" : "\(hostName) · \(text)"
        case .none: hostName
        }
        let parts: [String?] = [
            AgentKind(rawKind: row.kind).displayName, row.workspace, String(localized: row.status.title),
            row.isPinned ? String(localized: "Pinned") : nil, row.isMuted ? String(localized: "Muted") : nil,
            row.isAway ? String(localized: "New since you were away") : nil,
            preview.isEmpty ? nil : preview, row.time?.text(),
            row.progress?.contextPercent.map { String(localized: "Context \($0)%") },
            row.progress.flatMap { $0.todoTotal > 0 ? String(localized: "Todos \($0.todoDone) of \($0.todoTotal) done") : nil },
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// 「While away」,算出輪數後是「While away · +N turns」(#308)。
    static func awayBadgeText(turns: Int?) -> String {
        guard let turns, turns > 0 else { return String(localized: "While away") }
        let turnsText = String(localized: "\(turns) turns")
        return String(localized: "While away · +\(turnsText)")
    }

    /// AX 字級時不限制行數(DESIGN.md:支援到 AX5 不截斷)。
    private func lines(_ limit: Int) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : limit
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // 第一行是 workspace 名稱(#269,原型 B);聊天標題在對話裡。
            Text(row.workspace)
                .lineLimit(lines(1))
            // 釘選、靜音：名稱後的小圖示，不只靠顏色(#37 故事 18)。
            if row.isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(secondary)
                    .accessibilityLabel(Text("Pinned"))
            }
            if row.isMuted {
                Image(systemName: "bell.slash.fill")
                    .imageScale(.small)
                    .foregroundStyle(secondary)
                    .accessibilityLabel(Text("Muted"))
            }
            // 離開超過 15 分鐘後有新回覆(#308):名稱後的小標籤，文字說明、不只靠顏色。
            if row.isAway {
                Text(Self.awayBadgeText(turns: row.awayTurns))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
                    .accessibilityHidden(true)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
                trailingColumn
            }
        }
        .font(.body)
    }

    /// 小主機圖示(「無」不畫)與「主機 · 最後一句」;需要你時是「主機 · 等你回覆」。
    private var previewLine: some View {
        HStack(alignment: .top, spacing: 5) {
            if let icon = host?.icon, icon.symbol != nil {
                HostIconBadge(icon, diameter: 18)
            }
            previewText
            if let todos = row.progress, todos.todoTotal > 0 {
                Spacer(minLength: 4)
                TodoCount(done: todos.todoDone, total: todos.todoTotal)
            }
        }
    }

    private var previewText: some View {
        let hostName = host?.name ?? ""
        return Group {
            switch row.preview {
            case .needsInput:
                Text("\(hostName) · \(Text("Waiting for your input").fontWeight(.semibold).foregroundStyle(Color.primary))")
            case .message(let text, let fromYou):
                fromYou ? Text("\(hostName) · You: \(text)") : Text(verbatim: "\(hostName) · \(text)")
            case .none:
                Text(verbatim: hostName)
            }
        }
        .foregroundStyle(secondary)
    }

    /// 右欄：時間，下方是 context 小圓環與百分比(#307;對 VoiceOver 隱藏，念在整列句子裡)。
    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            timeText
            if let percent = row.progress?.contextPercent {
                ContextMeter(percent: percent)
            }
        }
    }

    @ViewBuilder
    private var timeText: some View {
        if let time = row.time {
            Text(time.text())
                .font(.footnote)
                .foregroundStyle(secondary)
        }
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

extension AgentRow {
    /// 列表骨架的佔位列(`redacted` 畫成灰條，對 VoiceOver 隱藏)。
    static func placeholder(_ index: Int) -> AgentRow {
        AgentRow(
            paneID: "placeholder-\(index)", title: "Agent name placeholder", subtitle: "",
            preview: .message("The latest message from this agent", fromYou: false), time: nil, status: .idle)
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
        case .working: "ellipsis.circle"
        // 實心圓 = 有未讀的回覆、空心圓 = 已讀(行為規格 F2.5;列表會把未讀折算成 done、已讀折算成 idle)。
        case .done: "circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

extension EnvironmentValues {
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
