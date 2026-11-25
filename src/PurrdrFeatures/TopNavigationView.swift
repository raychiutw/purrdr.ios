import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 一個視窗的頂層導覽(#37 故事 21、#31)。
///
/// 底部 4 個 tab:聊天、檔案、主機、流量(#376;設定併進帳號 sheet,#503);帳號與設定、新增聊天、付費牆與歡迎頁以 sheet 開啟。
/// 聊天 tab 依可用寬度排版(size class,不看裝置):寬視窗是兩欄 `NavigationSplitView`:Agent 列表(Spaces)→ 對話(#518;主機只看列表頂列的電腦圖示);
/// 窄的視窗(iPhone、iPad 窄視窗、iPhone Duo 外螢幕)是 `NavigationStack`,從 Agent 列表開始，點列推入對話(對話與終端機隱藏 tab bar)。
/// 導覽狀態每個視窗一份(`TopNavigationModel`);Agent 列表本身(`AgentListView`)不知道有哪些 sheet。
public struct TopNavigationView: View {
    @State private var navigation: TopNavigationModel
    /// 傳給子畫面的閉包(穩定物件,#581);根畫面重算時不產生新閉包。
    @State private var actions: RootActions
    /// 聊天 tab 的徽章數字(#581);只有小 View `RootTabs` 讀它。
    @State private var badge: NeedsYouBadge
    /// 兩欄預設都顯示。
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.allowsTestingLinks) private var allowsTestingLinks

    public init(
        hosts: HostsModel, member: MemberModel, settings: SettingsModel, plus: SubscriptionModel? = nil,
        hostSync: HostSyncModel? = nil, notifications: PushNotificationRouter? = nil, welcome: WelcomeModel? = nil,
        appLock: AppLock? = nil, inspectorStore: any InspectorVisibilityStore = UserDefaultsInspectorVisibilityStore()
    ) {
        let navigation = TopNavigationModel(inspectorStore: inspectorStore)
        _navigation = State(initialValue: navigation)
        _actions = State(initialValue: RootActions(navigation: navigation, hosts: hosts))
        _badge = State(initialValue: NeedsYouBadge(merged: hosts.agentList))
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
        tabs
            .environment(\.usageSections, UsageSectionContext(hosts: hosts))
            // 對話頂部的跨聊天「需要你」橫幅(#530):點了把目前的聊天換成那個聊天。
            .registersAsMainWindow()
            .environment(\.needsYouBanner, NeedsYouBannerContext(merged: hosts.agentList, open: actions.openBannerChat))
            // 選單列與快捷鍵作用在有焦點的視窗(`PurrdrCommands`)。
            .modifier(WindowCommandsModifier(navigation: navigation, hosts: hosts))
            .tailscaleCheckPrompt(hosts.tailscaleCheck)
            .sheet(item: $navigation.sheet) { sheet in
                Group {
                switch sheet {
                case .member:
                    // 帳號與設定頁(#246、#503)自帶 NavigationStack 與右上角 X;設定併在第一層。
                    MemberView(model: member, plus: plus, pushes: hosts.hostPushes, pushDevices: hosts.pushDevices, hostSync: hostSync,
                        hosts: hosts,
                        settings: AccountSettings(model: settings, openWelcome: { navigation.showWelcome() }, appLock: appLock))
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
                        // 進入 Demo 主機(空列表也進得去)並回到列表。
                        navigation.welcomeTryDemo(hosts: hosts)
                    } addHost: {
                        navigation.welcomeAddHost()
                    } rate: {
                        settings.rateApp()
                    } done: {
                        navigation.sheet = nil
                    }
                case .newChat:
                    NewChatSheet(
                        hosts: hosts, picker: hosts.screens.newChatHostPicker(preferring: navigation.newChatPreselection?.host),
                        preselection: navigation.newChatPreselection
                    ) {
                        navigation.sheet = nil
                    } onStarted: { workspace, host, unsentMessage in
                        // 先收起 sheet,再打開新 workspace 的聊天(否則聊天會推到 sheet 下面)。
                        navigation.sheet = nil
                        // agent 停在啟動問題時沒送的第一則訊息：放進聊天的輸入框，回答後自己送(#272)。
                        if let unsentMessage { hosts.member(for: host).keepDraft(unsentMessage, paneID: workspace.rootPaneID) }
                        Task { await hosts.openStartedChat(workspace, on: host) }
                    }
                }
                }
                .appSheetBackground()
            }
            // 第一次開啟 app:開出歡迎頁(#34)。
            .task { if let welcome { navigation.launched(welcome: welcome) } }
            // 冷啟動與從背景回來的深層連結都會走到這裡。
            .onOpenURL { url in openWhenUnlocked { navigation.open(url) } }
            // UI 測試:不重啟換字級(`purrdr://testing-content-size`),套到視窗讓 SwiftUI 與 UIKit 都跟著變。
            .task(id: allowsTestingLinks) { navigation.allowsTestingLinks = allowsTestingLinks }
            .onChange(of: navigation.testingContentSizeCategory) { _, category in
                TestingContentSize.apply(category)
            }
            .onChange(of: navigation.testingAppearance) { _, appearance in
                TestingContentSize.apply(appearance: appearance)
            }
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

    /// 聊天 tab:窄視窗是一般 `NavigationStack`(列表為根、聊天推入,轉場與主機 tab 的子頁一樣順),
    /// 寬視窗是兩欄。選取的聊天(`navigation.selectedChat`)兩種排版共用,縮放視窗時不丟失。
    @ViewBuilder
    private var chatsRoot: some View {
        if sizeClass == .compact {
            compactStack
        } else {
            splitView
        }
    }

    /// 窄視窗:Agent 列表為根,選到的聊天(對話或 Pane 終端機)推入;返回時選取清成 `nil`。
    private var compactStack: some View {
        @Bindable var navigation = navigation
        return NavigationStack {
            agentList
                .navigationDestination(item: $navigation.selectedChat) { route in
                    WindowDetailContent(hosts: hosts, navigation: navigation, route: route)
                        .appNavigationBackground()
                        // 換一個聊天(鍵盤切換、版面圖選 Pane)就整個重建(對話 model、推入的終端機)。
                        .id(route)
                }
        }
    }

    /// 兩欄(寬視窗)。
    private var splitView: some View {
        let navigation = navigation
        return NavigationSplitView(columnVisibility: $columns) {
            // 所有主機合併的 Agent 列表(#39)。換選取中主機不重建列表，只改排序與主機名標示。
            agentList
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            WindowDetail(
                hosts: hosts, navigation: navigation,
                account: AccountButtonPlacement.showsInDetailToolbar(for: .chats, isWideWindow: isWideWindow) ? accountButton : nil)
        }
    }

    /// 寬視窗(regular 水平 size class):聊天分兩欄,帳號頭像在最右邊那欄(#520);窄視窗收成一疊,在列表頂列。依可用寬度,不看裝置。
    private var isWideWindow: Bool { horizontalSizeClass == .regular }

    private var accountButton: AnyView {
        AnyView(TopBarAccountButton(member: member) { navigation.sheet = .member })
    }

    /// 所有主機合併的 Agent 列表(#39)。
    private var agentList: some View {
        let hosts = hosts
        var open: ((PaneWindow.Kind, ChatRoute, String) -> Void)?
        if supportsMultipleWindows {
            open = { kind, route, title in openInNewWindow(kind, route, title) }
        }
        let topBar = ChatTopBarActions(
            newChat: actions.newChat,
            newChatInWorkspace: actions.newChatInWorkspace,
            canNewChatInWorkspace: actions.canNewChatInWorkspace,
            addHost: actions.addHost,
            account: AccountButtonPlacement.showsInTopBar(for: .chats, isWideWindow: isWideWindow) ? accountButton : nil)
        return AgentListView(
            model: hosts.agentList, window: navigation, openInNewWindow: open, topBar: topBar,
            prefetchConversations: actions.prefetchConversations
        ) { route, sessionID in
            hosts.member(for: route.host).conversation(route, sessionID: sessionID)
        } terminal: { route, title in
            hosts.member(for: route.host).terminal(paneID: route.paneID, title: title)
        }
    }

    /// 把列表上的 Agent 開在新視窗(context menu,HIG Windows)。任何一台主機的 Agent 都可以(每台主機各自連線,#39)。
    private func openInNewWindow(_ kind: PaneWindow.Kind, _ route: ChatRoute, _ title: String) {
        openWindow(value: PaneWindow(
            kind: kind, host: route.host, paneID: route.paneID, sessionID: hosts.agentList.sessionID(of: route), title: title))
    }

    /// 4 個 tab。徽章數字在小 View `RootTabs` 讀(#581)。
    private var tabs: some View {
        RootTabs(
            navigation: navigation, hosts: hosts, member: member, plus: plus, badge: badge,
            chats: chatsRoot.selectedHostTheme(hosts).tint(ProminentFillStyle()))
    }
}

/// 4 個 tab 的容器。只有它讀聊天 tab 的徽章數字(`NeedsYouBadge`):數量變了只重算這一層,根畫面不重算(#581)。
/// 每個 tab 的頂列一致:中間是這頁看什麼,右上依 tab 不同,最右上角是帳號鈕。
private struct RootTabs<Chats: View>: View {
    let navigation: TopNavigationModel
    let hosts: HostsModel
    let member: MemberModel
    let plus: SubscriptionModel?
    let badge: NeedsYouBadge
    let chats: Chats

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: Binding(
            get: { TopLevelTab.visibleSelection(navigation.tab, visible: TopLevelTab.allCases) },
            set: { navigation.tab = $0 })) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: TopLevelTab.chats) {
                // 選取中主機的主題(#23)只套在聊天 tab 的列表、對話與終端機。
                chats
            }
            .badge(badge.count)
            Tab("Files", systemImage: "folder.fill", value: TopLevelTab.files) {
                FilesTab(hosts: hosts, member: member, openAccount: { navigation.sheet = .member }, addHost: { navigation.openAddHost() })
                    .tint(ProminentFillStyle())
            }
            Tab("Hosts", systemImage: "desktopcomputer", value: TopLevelTab.hosts) {
                HostsTab(
                    hosts: hosts, member: member, plus: plus, importURL: $navigation.pendingHostImport,
                    editHostID: $navigation.pendingHostEditor, addHost: $navigation.pendingAddHost,
                    openAccount: { navigation.sheet = .member }, openAddHost: { navigation.openAddHost() },
                    openPlus: { navigation.sheet = .plus }, didEnterDemo: { navigation.tab = .chats })
                    .tint(ProminentFillStyle())
            }
            Tab("Traffic", systemImage: "arrow.up.arrow.down.circle.fill", value: TopLevelTab.traffic) {
                TrafficTab(hosts: hosts, member: member, openAccount: { navigation.sheet = .member })
                    .tint(ProminentFillStyle())
            }
        }
        // tab bar 選取態的顏色(DESIGN.md「深色層次與新色票」);內容各自把 tint 還原成主色。
        .tint(AccessibleColors.tabSelection.color)
        .task { badge.start() }
    }
}

/// 視窗指令(選單列與快捷鍵)的接線(#581):body 只查選取的聊天(`windowTarget`),不對所有主機做完整 Spaces 投影;
/// 放在 ViewModifier 裡,資料變了只重算這一層,不連累根畫面。
private struct WindowCommandsModifier: ViewModifier {
    let navigation: TopNavigationModel
    let hosts: HostsModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.windowCommands, windowCommands)
    }

    private var windowCommands: WindowCommands {
        let navigation = navigation
        let hosts = hosts
        let target = hosts.agentList.windowTarget(for: navigation.selectedChat)
        let opening = target.opening
        let openWindow = openWindow
        let context = KeyboardCommandContext(
            hasSelectedChat: opening != nil, hasSelectedConversation: target.hasConversation, tab: navigation.tab,
            isWideWindow: sizeClass != .compact, isInspectorShown: navigation.isInspectorShown,
            supportsMultipleWindows: supportsMultipleWindows)
        return WindowCommands(perform: { command in
            if command == .openInNewWindow {
                if let route = navigation.selectedChat, let opening {
                    openWindow(value: PaneWindow(
                        kind: opening.isTerminal ? .terminal : .chat, host: route.host, paneID: route.paneID,
                        sessionID: hosts.agentList.sessionID(of: route), title: opening.title))
                }
                return
            }
            // 執行時才算完整投影(切換聊天的快捷鍵),不在 body 裡讀。
            navigation.perform(command, visibleAgents: navigation.visibleAgents(hosts.agentList.spacesSections))
        }, context: context)
    }
}

/// 根畫面傳給子畫面的閉包(#581):一份穩定物件,根畫面重算時不產生新閉包。
@MainActor
final class RootActions {
    let openBannerChat: @MainActor (ChatRoute) -> Void
    let newChat: () -> Void
    let newChatInWorkspace: (HostSelection, String) -> Void
    let canNewChatInWorkspace: (HostSelection) -> Bool
    let addHost: () -> Void
    let prefetchConversations: @MainActor ([ChatRoute]) async -> Void

    init(navigation: TopNavigationModel, hosts: HostsModel) {
        openBannerChat = { [weak navigation] in navigation?.selectedChat = $0 }
        newChat = { [weak navigation] in navigation?.sheet = .newChat }
        newChatInWorkspace = { [weak navigation] in navigation?.startNewChat(inWorkspace: $1, on: $0) }
        canNewChatInWorkspace = { [weak hosts] in hosts?.supportsNewChatInWorkspace($0) ?? false }
        addHost = { [weak navigation] in navigation?.openAddHost() }
        prefetchConversations = { [weak hosts] in await hosts?.prefetchConversations($0) }
    }
}

/// 新增對話的 sheet:主機挑選鈕在 sheet 開啟時建立一次;換主機就在那台主機重建表單(#245)。
private struct NewChatSheet: View {
    let hosts: HostsModel
    @State private var picker: HostPickerModel
    let preselection: NewChatPreselection?
    let onCancel: () -> Void
    let onStarted: (CreatedWorkspace, HostSelection, String?) -> Void

    init(
        hosts: HostsModel, picker: @autoclosure () -> HostPickerModel, preselection: NewChatPreselection?, onCancel: @escaping () -> Void,
        onStarted: @escaping (CreatedWorkspace, HostSelection, String?) -> Void
    ) {
        self.hosts = hosts
        _picker = State(wrappedValue: picker())
        self.preselection = preselection
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    var body: some View {
        let host = picker.selection
        // 預選只在主機沒被改掉時有效。
        let preselected = preselection.flatMap { $0.host == host ? $0.workspaceID : nil }
        NewChatForm(model: hosts.member(for: host).newChat(preselectingWorkspace: preselected), picker: picker, onCancel: onCancel) { onStarted($0, host, $1) }
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

/// 電腦圖示的選單內容(#244、#499):所有主機或某一台,改「目前主機」;選某一台時同時設成選取中主機。最下面是「新增主機…」。
struct CurrentHostMenu: View {
    @Bindable var list: MergedAgentListModel
    /// 選單最下面的「新增主機…」。
    var addHost: (() -> Void)?

    var body: some View {
        Picker(selection: $list.currentHost) {
            Label("All Hosts", systemImage: "square.grid.2x2")
                .tag(HostSelection?.none)
            ForEach(list.hostFilterOptions) { option in
                HostMenuLabel(option)
                    .tag(HostSelection?.some(option.id))
            }
        } label: {
            Text("Hosts")
        }
        .accessibilityIdentifier("currentHost.picker")
        if let addHost {
            Divider()
            Button("Add Host…", systemImage: "plus", action: addHost)
                .accessibilityIdentifier("hostMenu.addHost")
        }
    }
}
