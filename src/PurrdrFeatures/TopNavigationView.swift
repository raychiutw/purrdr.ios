import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 一個視窗的頂層導覽(#37 故事 21、#31)。
///
/// 三欄 `NavigationSplitView`:主機與 workspace → Agent 列表 → 對話。依可用寬度排版(size class,不看裝置):
/// 窄的視窗(iPhone、iPad 窄視窗、iPhone Duo 外螢幕)收合成一疊，從 Agent 列表開始，點列推入對話。
/// 列表工具列有「⋯」選單(第一項是新增聊天),其餘畫面以 sheet 開啟;不採 tab bar。
/// 導覽狀態每個視窗一份(`TopNavigationModel`);Agent 列表本身(`AgentListView`)不知道有哪些 sheet。
public struct TopNavigationView: View {
    @State private var navigation = TopNavigationModel()
    /// 窄視窗收合時顯示哪一欄：從 Agent 列表開始。
    @State private var compactColumn = NavigationSplitViewColumn.content
    /// 預設不隱藏側欄(HIG Sidebars);使用者可以邊緣滑動收起。
    @State private var columns = NavigationSplitViewVisibility.all
    let hosts: HostsModel
    let member: MemberModel
    let settings: SettingsModel
    /// Purrdr Plus(#28);`nil` 時不提供付費牆。
    let plus: SubscriptionModel?
    /// 主機同步(#30);`nil` 時設定頁不顯示。
    let hostSync: HostSyncModel?
    /// 點了推播通知(#29);`nil` 時沒有推播。
    let notifications: PushNotificationRouter?
    /// 第一次開啟的歡迎頁(#34);`nil` 時不自動開出。
    let welcome: WelcomeModel?
    /// App 鎖(#284);推播開啟的導航等解鎖後才執行。`nil` 時沒有 App 鎖。
    let appLock: AppLock?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 從「⋯」選單推進來的主機工具(登入 Shell、檔案瀏覽、方案用量)。
    @State private var hostTool: HostTool?

    public init(
        hosts: HostsModel, member: MemberModel, settings: SettingsModel, plus: SubscriptionModel? = nil,
        hostSync: HostSyncModel? = nil, notifications: PushNotificationRouter? = nil, welcome: WelcomeModel? = nil,
        appLock: AppLock? = nil
    ) {
        self.welcome = welcome
        self.appLock = appLock
        self.hostSync = hostSync
        self.hosts = hosts
        self.member = member
        self.settings = settings
        self.plus = plus
        self.notifications = notifications
    }

    public var body: some View {
        @Bindable var navigation = navigation
        splitView
            // 選取中主機的主題(#23)只套在側欄、列表、對話與終端機;sheet(設定)接在後面，維持 App 配色。
            .selectedHostTheme(hosts)
            .onChange(of: hosts.selection) { navigation.hostChanged() }
            .onChange(of: sizeClass, initial: true) { _, sizeClass in
                if sizeClass == .compact { navigation.workspaceFilter = nil }
            }
            // 選單列與快捷鍵作用在有焦點的視窗(`PurrdrCommands`)。
            .focusedSceneValue(\.windowCommands, windowCommands)
            .tailscaleCheckPrompt(hosts.tailscaleCheck)
            .sheet(item: $navigation.sheet) { sheet in
                switch sheet {
                case .hosts:
                    HostListView(model: hosts, importURL: $navigation.pendingHostImport, editHostID: $navigation.pendingHostEditor, addHost: $navigation.pendingAddHost)
                case .settings:
                    SettingsView(
                        model: settings,
                        openWelcome: { navigation.showWelcome() }, appLock: appLock,
                        dataUsage: { hosts.dataUsage() }
                    ) {
                        navigation.sheet = nil
                    }
                case .member:
                    // 帳號頁(#246)自帶 NavigationStack 與「完成」。
                    MemberView(model: member, plus: plus, pushes: hosts.hostPushes, pushDevices: hosts.pushDevices, hostSync: hostSync,
                        hosts: hosts)
                        // 通知區塊依主機服務版本判斷 HTTPS 主機能不能開。
                        .task { await hosts.checkHostServiceVersions() }
                case .plus:
                    if let plus {
                        PlusSheet(model: plus, member: member, features: PlusFeatureLinks(
                            status: PlusFeatureStatus(
                                notifyingHostCount: hosts.hostPushes.notifyingHostNames.count,
                                isHostSyncOn: hostSync?.isEnabled ?? false,
                                deviceCount: hosts.pushDevices.flatMap { $0.hasLoaded ? $0.devices.count : nil }),
                            // 前往帳號頁:換成帳號 sheet(捲到對應區塊留給帳號頁自己)。
                            open: { _ in navigation.sheet = .member }))
                    }
                case .welcome:
                    WelcomeView {
                        // 選 Demo 主機(已有主機時 Demo 也會出現在列表上)並回到列表。
                        hosts.select(.demo)
                        navigation.sheet = nil
                    } addHost: {
                        navigation.welcomeAddHost()
                    } rate: {
                        settings.rateApp()
                    } done: {
                        navigation.sheet = nil
                    }
                case .newChat:
                    NewChatSheet(hosts: hosts, picker: hosts.newChatHostPicker()) {
                        navigation.sheet = nil
                    } onStarted: { workspace, host, unsentMessage in
                        // 先收起 sheet,再打開新 workspace 的聊天(否則聊天會推到 sheet 下面)。
                        navigation.sheet = nil
                        // agent 停在啟動問題時沒送的第一則訊息：放進聊天的輸入框，回答後自己送(#272)。
                        if let unsentMessage { hosts.keepDraft(unsentMessage, for: ChatRoute(host: host, paneID: workspace.rootPaneID)) }
                        Task { await hosts.openStartedChat(workspace, on: host) }
                    }
                }
            }
            // 第一次開啟 app:開出歡迎頁(#34)。
            .task { if let welcome { navigation.launched(welcome: welcome) } }
            // 冷啟動與從背景回來的深層連結都會走到這裡。
            .onOpenURL { navigation.open($0) }
            // StoreKit 的交易更新(續訂、別台裝置購買、兌換 Offer Code、未 finish 的交易)從啟動就要接。
            .task { await plus?.observeTransactionUpdates() }
            // 主機同步(開啟時):啟動時拿別台裝置的修改。
            .task { await hostSync?.sync() }
            // 連線韌性(行為規格 §7.4、§7.5):網路切換丟棄連線;背景太久回前景先探測連線。
            .task {
                for await signature in NetworkPaths.signatures() { hosts.networkPathChanged(signature) }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: hosts.sceneDidEnterBackground(at: .now)
                case .active:
                    Task { await hosts.sceneDidBecomeActive(at: .now) }
                    // 主機同步(開啟時):回到前景拿別台裝置的修改。
                    Task { await hostSync?.sync() }
                default: break
                }
            }
            // 推播：APNs token 換了就向後台重新註冊(不請求權限)。
            .task { await hosts.refreshPushRegistrations() }
            // 點了通知：先收起 sheet(否則聊天會推到 sheet 下面),再開該 Agent 的聊天;主機服務通知開那台主機的編輯頁(#293)。
            // App 鎖定中等解鎖後才開(#284)。
            .onChange(of: notifications?.pending, initial: true) { _, route in
                guard let route else { return }
                notifications?.pending = nil
                openWhenUnlocked {
                    navigation.sheet = nil
                    if case .hostEditor(let id) = hosts.open(route) { navigation.openHostEditor(id) }
                }
            }
    }

    /// 推播等從 app 外部開啟的導航：App 鎖定中延到解鎖後(只留最後一個)。
    private func openWhenUnlocked(_ navigation: @escaping @MainActor () -> Void) {
        guard let appLock else { return navigation() }
        appLock.whenUnlocked(navigation)
    }

    private var windowCommands: WindowCommands {
        let navigation = navigation
        let hosts = hosts
        let card = navigation.layoutCard
        return WindowCommands(
            perform: { command in
                let list = hosts.agentList
                navigation.perform(
                    command,
                    visibleAgents: navigation.visibleAgents(list.sections, host: hosts.selection, snapshot: list.snapshot(for: hosts.selection)))
            },
            isLayoutCardShown: card.workspaceID != nil,
            closeLayoutCard: { card.close() })
    }

    /// 三欄(窄視窗收合成一疊)。
    private var splitView: some View {
        let navigation = navigation
        return NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            WindowSidebar(hosts: hosts, navigation: navigation)
        } content: {
            // 所有主機合併的 Agent 列表(#39)。換選取中主機不重建列表，只改排序與主機名標示。
            agentList
                .toolbar { toolbar }
                // 登入 Shell、檔案瀏覽:窄視窗推疊在列表上;三欄時顯示在對話欄。
                .navigationDestination(item: $hostTool) { tool in
                    switch tool {
                    case .loginShell(let picker):
                        LoginShellScreen(hosts: hosts, picker: picker)
                    case .files(let picker):
                        FilesScreen(hosts: hosts, picker: picker)
                    case .planUsage(let model):
                        PlanUsageView(model: model)
                    }
                }
                #if os(iOS)
                // 窄視窗不顯示回到側欄的返回鈕：主機從「⋯」選單進入(iPhone 頂層導覽);workspace 篩選只在側欄看得到時套用。
                .navigationBarBackButtonHidden(sizeClass == .compact)
                #endif
                .overlay(alignment: .topLeading) {
                    LayoutCardOverlay(
                        card: navigation.layoutCard, snapshot: hosts.agentList.snapshot(for: hosts.selection), onChoose: openLayoutTarget)
                }
        } detail: {
            WindowDetail(hosts: hosts, navigation: navigation)
        }
    }

    /// 所有主機合併的 Agent 列表(#39)。
    private var agentList: some View {
        let hosts = hosts
        var open: ((PaneWindow.Kind, AgentRow) -> Void)?
        if supportsMultipleWindows {
            open = { kind, row in openInNewWindow(kind, row) }
        }
        return AgentListView(model: hosts.agentList, window: navigation, openInNewWindow: open) { route, sessionID in
            hosts.conversation(route, sessionID: sessionID)
        } terminal: { route, title in
            hosts.terminal(route, title: title)
        }
    }

    /// 把列表上的 Agent 開在新視窗(context menu,HIG Windows)。任何一台主機的 Agent 都可以(每台主機各自連線,#39)。
    private func openInNewWindow(_ kind: PaneWindow.Kind, _ row: AgentRow) {
        openWindow(value: PaneWindow(
            kind: kind, host: row.host, paneID: row.paneID, sessionID: hosts.agentList.sessionID(of: row.route), title: row.title))
    }

    /// 版面圖卡片(選取中主機的 workspace)選了 Pane:Agent 在對話欄打開;終端機方塊在對話欄開它的 Pane 終端機。
    private func openLayoutTarget(_ target: PaneOpenTarget) {
        switch target {
        case .chat(let paneID):
            navigation.selectedChat = ChatRoute(host: hosts.selection, paneID: paneID)
        case .terminal(let paneID):
            // 終端機方塊：在對話欄開它的 Pane 終端機(#40;對話欄依 pane 是否為 Agent 決定)。
            navigation.selectedChat = ChatRoute(host: hosts.selection, paneID: paneID)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // 主機篩選(#244):選某台主機時同時設成選取中主機。
        ToolbarItem(placement: Self.hostPlacement) {
            HostFilterMenu(list: hosts.agentList)
        }
        ToolbarItem(placement: .primaryAction) {
            // 以 Divider 分組;不包 Section:包了之後 XCUITest 找不到選單項目的 identifier。
            Menu {
                // AX 字級時帳號併進這個選單(#268):工具列只剩主機篩選與「⋯」,不會被系統收進溢出選單，
                // 選單項目維持一層(否則溢出選單裡「⋯」變成「更多 ›」第二層)。
                if dynamicTypeSize.isAccessibilitySize {
                    Button("Account", systemImage: "person.crop.circle") { navigation.sheet = .member }
                        .accessibilityIdentifier("menu.account")
                    Divider()
                }
                let groups = MoreMenuItem.groups(supportsShell: hosts.anyHostSupportsShell)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { item in
                        moreMenuButton(item)
                            .accessibilityIdentifier(item.accessibilityIdentifier)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("toolbar.more")
        }
        // 帳號鈕(#246):最右上角(HIG),「⋯」在它左邊;開帳號頁。AX 字級時改在「⋯」選單裡(見上)。
        if !dynamicTypeSize.isAccessibilitySize {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                AccountButton(member: member) { navigation.sheet = .member }
            }
            // 頭像本身就是圓形，不再包一層玻璃。
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// 「⋯」選單的一項。登入 Shell 與檔案預設上次選的主機，畫面上可換(#245;iPad 上也是推疊)。
    @ViewBuilder
    private func moreMenuButton(_ item: MoreMenuItem) -> some View {
        switch item {
        case .newChat:
            Button("New Chat", systemImage: "plus") { navigation.sheet = .newChat }
        case .hosts:
            Button("Computers", systemImage: "desktopcomputer") { navigation.sheet = .hosts }
        case .planUsage:
            // 方案用量(#177):獨立畫面，選主機與 Agent 後查詢。
            Button("Plan Usage", systemImage: "gauge.with.dots.needle.33percent") { hostTool = .planUsage(hosts.planUsage()) }
        case .loginShell:
            Button("Login Shell", systemImage: "apple.terminal") { hostTool = .loginShell(hosts.hostPicker(for: .loginShell)) }
        case .files:
            Button("Files", systemImage: "folder") { hostTool = .files(hosts.hostPicker(for: .files)) }
        case .settings:
            Button("Settings", systemImage: "gearshape") { navigation.sheet = .settings }
        }
    }
}

extension TopNavigationView {
    #if os(iOS)
    static let hostPlacement = ToolbarItemPlacement.topBarLeading
    #else
    static let hostPlacement = ToolbarItemPlacement.navigation
    #endif
}

/// 從「⋯」選單推進來的主機工具。每次打開都是新的 model(新的 shell、從家目錄開始、方案用量重新查一次);
/// 登入 Shell 與檔案帶主機挑選鈕，換主機時畫面自己重建 model。
enum HostTool: Hashable {
    case loginShell(HostPickerModel)
    case files(HostPickerModel)
    case planUsage(PlanUsageModel)

    private var object: AnyObject {
        switch self {
        case .loginShell(let model): model
        case .files(let model): model
        case .planUsage(let model): model
        }
    }

    static func == (a: HostTool, b: HostTool) -> Bool { a.object === b.object }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(object)) }
}

/// 聊天列表右上角的帳號鈕(#246):會員的頭像字，未加入會員顯示「?」。
struct AccountButton: View {
    let member: MemberModel
    let action: () -> Void
    /// 跟旁邊「⋯」的玻璃圓鈕看起來一樣大(實機回報 2026-11-20):工具列玻璃鈕畫出來是 44pt
    /// (XCUI 回報的 frame 只有內容的 36pt);頭像是圖示，不隨字級放大。
    private let size: CGFloat = 44

    var body: some View {
        // 名稱放在 Label 標題與無障礙表示:AX 字級時系統把這顆收進工具列的溢出選單。
        Button(action: action) {
            Label {
                Text("Account")
            } icon: {
                AccountAvatar(member: signedInMember)
                    .font(.subheadline)
                    .frame(width: size, height: size)
                    .accessibilityRepresentation { Text("Account") }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Account"))
        .accessibilityIdentifier("toolbar.account")
        .task { if member.phase == .unknown { await member.restore() } }
    }

    private var signedInMember: Member? {
        if case .signedIn(let member) = member.phase { return member }
        return nil
    }
}

/// 新增對話的 sheet:主機挑選鈕在 sheet 開啟時建立一次;換主機就在那台主機重建表單(#245)。
private struct NewChatSheet: View {
    let hosts: HostsModel
    @State private var picker: HostPickerModel
    let onCancel: () -> Void
    let onStarted: (CreatedWorkspace, HostSelection, String?) -> Void

    init(
        hosts: HostsModel, picker: @autoclosure () -> HostPickerModel, onCancel: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace, HostSelection, String?) -> Void
    ) {
        self.hosts = hosts
        _picker = State(wrappedValue: picker())
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    var body: some View {
        let host = picker.selection
        NewChatForm(model: hosts.newChat(on: host), picker: picker, onCancel: onCancel) { onStarted($0, host, $1) }
            .id(host)
    }
}

/// 一台主機上的新增對話表單：model 建立一次，之後重繪不重建。
private struct NewChatForm: View {
    @State private var model: NewChatModel
    let picker: HostPickerModel
    let onCancel: () -> Void
    let onStarted: (CreatedWorkspace, String?) -> Void

    init(
        model: @autoclosure () -> NewChatModel, picker: HostPickerModel, onCancel: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace, String?) -> Void
    ) {
        _model = State(wrappedValue: model())
        self.picker = picker
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    var body: some View {
        NewChatView(model: model, hostPicker: picker, onCancel: onCancel, onStarted: onStarted)
    }
}

/// 左上角的主機篩選(#244):所有主機或某一台，選單帶主機圖示;選某一台時同時設成選取中主機。
struct HostFilterMenu: View {
    @Bindable var list: MergedAgentListModel

    var body: some View {
        let current = list.currentHost.flatMap { list.hostLabel(of: $0) }
        Menu {
            Picker(selection: $list.currentHost) {
                Label("All Computers", systemImage: "square.grid.2x2")
                    .tag(HostSelection?.none)
                ForEach(list.hostFilterOptions) { option in
                    HostMenuLabel(option.name, icon: option.icon)
                        .tag(HostSelection?.some(option.id))
                }
            } label: {
                Text("Computers")
            }
            .accessibilityIdentifier("currentHost.picker")
        } label: {
            // 工具列的 Label 只畫圖示，自己排「主機圖示＋名稱＋▾」(原型 purrdr-screens.html);膠囊由工具列玻璃提供。
            HStack(spacing: 6) {
                HostIconBadge(current?.icon ?? .default, diameter: 24)
                Group {
                    if let current {
                        Text(verbatim: current.name)
                    } else {
                        Text("All Computers")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.trailing, 4)
        }
        // 工具列的 Menu 不會把 accessibilityValue 帶給 VoiceOver,篩選放進 label。
        .accessibilityLabel(current.map { Text("Showing: \($0.name)") } ?? Text("Showing: All Computers"))
        .accessibilityIdentifier("toolbar.currentHost")
    }
}
