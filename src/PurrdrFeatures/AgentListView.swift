import PurrdrCore
import SwiftUI

/// Agent 列表(DESIGN.md 方向 A):系統 grouped list,依「已釘選／需要你／工作中／閒置」分 section,標題帶數量。
///
/// 所有主機的 Agent 合併在同一個列表(#39):非選取中主機的列在副標開頭標示主機名;某台主機連不上時保留它最後的列，
/// 列表下方顯示「主機名：原因」。沒有任何列時，選取中主機的錯誤才佔滿畫面。
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
    /// 選取中主機的 Claude 用量，畫在列表最下方;讀取失敗時不顯示(行為規格 F2.9、F18)。
    private let usage: ClaudeUsageModel?
    /// 所在視窗的導覽狀態(#31)。有的話：列是 split view 的選取(對話顯示在對話欄)、套用側欄的 workspace 篩選;
    /// 沒有的話列表自己推入對話。
    private let window: TopNavigationModel?
    /// 把 Agent 對話或終端機開在新視窗(支援多視窗時才有)。
    private let openInNewWindow: ((PaneWindow.Kind, AgentRow) -> Void)?
    @FocusState private var searchFocused: Bool
    @State private var showingNotes = false

    public init(
        model: MergedAgentListModel, usage: ClaudeUsageModel? = nil, window: TopNavigationModel? = nil,
        openInNewWindow: ((_ kind: PaneWindow.Kind, _ row: AgentRow) -> Void)? = nil,
        conversation: @escaping @MainActor (_ route: ChatRoute, _ sessionID: String?) -> ConversationModel,
        terminal: (@MainActor (_ route: ChatRoute, _ title: String) -> PaneTerminalModel)? = nil
    ) {
        self.model = model
        self.makeConversation = conversation
        self.makeTerminal = terminal
        self.usage = usage
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
        // 標題是目前檢視名，點標題切換 Spaces／Agents(行為規格 F2.1、#37 故事 7)。系統的標題選單(標題旁有 ⌄)
        // 在大標題模式不出現，iOS 26 的 `.largeTitle` 自訂項目又不在 accessibility tree 裡，所以列表標題用 inline。
        .navigationTitle(model.mode.title)
        .toolbarTitleMenu { AgentListModePicker(mode: $model.mode) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 「You should know」:每台主機各自輪詢(列表可見且在前景時，#23)。
        .task(id: RunKey(active: scenePhase == .active, lists: model.runKey)) {
            guard scenePhase == .active else { return }
            await model.runNotes()
        }
        .sheet(isPresented: $showingNotes) {
            YouShouldKnowListView(entries: model.notes) { model.openedChat = $0 }
        }
        .task(id: RunKey(active: scenePhase == .active, lists: model.runKey)) {
            guard scenePhase == .active else { return }
            // 同一份列表開在好幾個視窗時，每台主機的即時更新各只跑一份(`AgentListModel.liveUpdates`,#31)。
            await model.run()
        }
    }

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
            ProgressView("Loading agents…")
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

    private var list: some View {
        let sections = sections
        return Group {
            // split view 的內容欄：列是選取(持續高亮，HIG 20.9);獨立的 NavigationStack 裡則是推入。
            if window != nil {
                List(selection: selection) {
                    notesRow
                    listRows(sections)
                }
            } else {
                List {
                    notesRow
                    listRows(sections)
                }
            }
        }
        .environment(\.swipeHintList, model)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
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
        .searchable(text: $model.query, prompt: Text("Search"))
        // Command-F(#31):視窗的導覽狀態要求搜尋欄取得焦點。
        .searchFocused($searchFocused)
        .onChange(of: window?.isSearchFocused ?? false) { _, focused in
            if focused { searchFocused = true }
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused { window?.isSearchFocused = false }
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    /// 列表最上方一行「✦ N 則註記」(#37 故事 49):所有主機、只算列表裡有的 Claude 聊天。
    @ViewBuilder
    private var notesRow: some View {
        let count = model.notes.count
        if count > 0 {
            Section { YouShouldKnowListRow(count: count) { showingNotes = true } }
        }
    }

    @ViewBuilder
    private func listRows(_ sections: [AgentSection]) -> some View {
        let failures = model.failures
        if model.mode == .spaces {
            SpacesSectionsContent(sections: spacesSections, model: model, presentation: presentation) { row in agentRow(row) }
        } else {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in agentRow(row) }
                } header: {
                    AgentSectionHeader(group: section.group, count: section.rows.count)
                }
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
        if let usage, list(failedFor: model.selected) == false {
            Section { ClaudeUsageFooter(model: usage) }
        }
        if model.showsSwipeHint, !(model.mode == .spaces ? spacesSections.isEmpty : sections.isEmpty) {
            // 第一次用滑動面板的動作之前，列表底部提示有哪些滑動動作(行為規格 F2.7)。
            Section {
                Label("Swipe a row left or right to pin, mute, rename, or close.", systemImage: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("agentList.swipeHint")
            }
        }
    }

    /// 一個 Agent 列(兩種檢視共用：同樣的滑動、選單、已讀與釘選)。
    private func agentRow(_ row: AgentRow) -> some View {
        NavigationLink(value: row.route) { AgentRowView(row: row) }
            .accessibilityIdentifier("agent.row.\(row.id)")
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
        let panes = Set(snapshot.agents.filter { $0.workspaceID == filter }.map(\.paneID))
        return all.compactMap { section in
            let items = section.items.filter { item in
                switch item {
                case .chat(let row): row.host == model.selected && panes.contains(row.paneID)
                case .card(let card): card.host == model.selected && card.workspaceID == filter
                }
            }
            return items.isEmpty ? nil : SpacesSection(group: section.group, items: items)
        }
    }

    /// 某台主機讀不到(Claude 用量只在選取中主機讀得到時顯示)。
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

struct AgentRowView: View {
    let row: AgentRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 選取中(iPad 的 split view 列以 tint 填滿)時是 `.increased`:次要色與 tint 字都要改成白色，
    /// 否則淡白／紅字疊在紅底上看不見(#35 iPad audit)。
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var isProminent: Bool { backgroundProminence == .increased }

    /// 次要色;選取中改白色。
    private var secondary: AnyShapeStyle { isProminent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondaryText) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // agent 種類圖示(#37 故事 6)。種類名稱已在副標裡，VoiceOver 不重複念。
            Image(systemName: AgentKindSymbol.name(for: row.kind))
                .font(.body)
                .foregroundStyle(secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            // AX 字級改成上下堆疊，不截斷(DESIGN.md)。不用 `ViewThatFits`:它比的是文字不換行的理想寬度，
            // 副標稍長(例如「Claude Code · demo/weather-app」)就在預設字級也堆疊，各列版面不一致(#35)。
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    texts
                    StatusLabel(status: row.status)
                    timeText
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    texts
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusLabel(status: row.status)
                        timeText
                    }
                    .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isUnread ? Text("Unread") : Text(verbatim: ""))
    }

    /// AX 字級時不限制行數(DESIGN.md:支援到 AX5 不截斷)。
    private func lines(_ limit: Int) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : limit
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.title)
                    .lineLimit(lines(2))
                // 釘選、靜音：標題後的小圖示，不只靠顏色(#37 故事 18)。VoiceOver 念「已釘選」「已靜音」(行為規格 F2.4 的順序)。
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
            }
            .font(.body)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // 非選取中主機：副標開頭的主機名前加主機圖示(#37 故事 2、5)。主機名在文字裡，圖示不念。
                if let label = row.hostLabel {
                    Image(systemName: label.icon.symbol)
                        .accessibilityHidden(true)
                }
                Text(row.subtitle)
                    .lineLimit(lines(1))
            }
            .font(.subheadline.monospaced())
            .foregroundStyle(secondary)
            preview
                .font(.subheadline)
                .lineLimit(lines(1))
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch row.preview {
        case .needsInput:
            Text("Waiting for your input")
                .foregroundStyle(isProminent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
        case .message(let text, let fromYou):
            Text(fromYou ? "You: \(text)" : "\(text)")
                .foregroundStyle(secondary)
        case .none:
            EmptyView()
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

/// Agent 狀態同時用文字、符號形狀與顏色表示，不只靠顏色(DESIGN.md)。
/// 顏色只上在符號：文字維持次要色，確保對比;「需要你」整個用 tint(品牌紅,`#D91E36` 對白底 5.0:1)。
struct StatusLabel: View {
    let status: AgentStatus
    /// 選取中的列(tint 填滿的底):符號與文字都用白色，形狀仍區分狀態。
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        let prominent = backgroundProminence == .increased
        // 不用 `Label`:在 List 列裡 Label 套的是列表樣式(圖示固定欄寬、標題對齊列文字),放進 `fixedSize` 的右側欄
        // 算不出理想寬度，標題被擠成極窄、一字一行，整列被撐高(#35)。
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: status.symbol)
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : status.color)
            Text(status.title)
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : status == .blocked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
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

/// 導覽入口旁的數字：需要處理的 workspace 數(行為規格 F2.8)。0 不畫;超過 99 顯示「99+」。不設 app 圖示徽章。
struct AttentionBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(verbatim: count > 99 ? "99+" : "\(count)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.tint))
                .accessibilityLabel(count == 1 ? Text("1 workspace needs you") : Text("\(count) workspaces need you"))
                .accessibilityIdentifier("attention.badge")
        }
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
    /// 狀態字：列表、版面圖、對話標題列共用這一份(`Text` 與 `String(localized:)` 都用它)。
    var title: LocalizedStringResource {
        switch self {
        case .blocked: "Needs You"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

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

    /// 語意對應 herdr 側欄(行為規格 F2.5);用系統色，深淺色與高對比由系統處理。
    var color: AnyShapeStyle {
        switch self {
        case .blocked: AnyShapeStyle(.tint)
        case .working: AnyShapeStyle(.orange)
        case .done: AnyShapeStyle(.teal)
        case .idle: AnyShapeStyle(.green)
        case .unknown: AnyShapeStyle(.gray)
        }
    }
}
