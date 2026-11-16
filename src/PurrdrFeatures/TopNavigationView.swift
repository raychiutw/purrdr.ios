import PurrdrCore
import SwiftUI

/// 一個視窗的頂層導覽(#37 故事 21、#31)。
///
/// 三欄 `NavigationSplitView`:主機與 workspace → Agent 列表 → 對話。依可用寬度排版(size class,不看裝置):
/// 窄的視窗(iPhone、iPad 窄視窗、iPhone Duo 外螢幕)收合成一疊，從 Agent 列表開始，點列推入對話。
/// 列表工具列有「⋯」選單與「+」,其餘畫面以 sheet 開啟;不採 tab bar。
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
    /// Purrdr Plus(#28);`nil` 時選單不顯示。
    let plus: SubscriptionModel?
    /// 主機同步(#30);`nil` 時設定頁不顯示。
    let hostSync: HostSyncModel?
    /// 點了推播通知(#29);`nil` 時沒有推播。
    let notifications: PushNotificationRouter?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// 從「⋯」選單推進來的主機工具(登入 Shell、檔案瀏覽)。
    @State private var hostTool: HostTool?

    public init(
        hosts: HostsModel, member: MemberModel, settings: SettingsModel, plus: SubscriptionModel? = nil,
        hostSync: HostSyncModel? = nil, notifications: PushNotificationRouter? = nil
    ) {
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
                    HostListView(model: hosts, importURL: $navigation.pendingHostImport)
                case .settings:
                    SettingsView(
                        model: settings, member: member, plus: plus, push: hosts.push, hostSync: hostSync,
                        openPlus: { navigation.sheet = .plus }, codexLauncher: hosts.codexLauncher,
                        attention: { hosts.agentList.attentionCount }
                    ) {
                        navigation.sheet = nil
                    }
                case .member:
                    // 會員畫面自帶 NavigationStack 與「完成」。
                    MemberView(model: member, plus: plus)
                case .plus:
                    if let plus {
                        PlusSheet(model: plus, member: member)
                    }
                case .newChat:
                    NewChatSheet(model: hosts.newChat()) {
                        navigation.sheet = nil
                    } onStarted: { workspace in
                        // 先收起 sheet,再打開新 workspace 的聊天(否則聊天會推到 sheet 下面)。
                        navigation.sheet = nil
                        Task { await hosts.openStartedChat(workspace) }
                    }
                }
            }
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
            // 點了通知：先收起 sheet(否則聊天會推到 sheet 下面),再切換主機、開該 Agent 的聊天。
            .onChange(of: notifications?.pending, initial: true) { _, route in
                guard let route else { return }
                notifications?.pending = nil
                navigation.sheet = nil
                hosts.open(route)
            }
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
                    case .loginShell(let model):
                        #if canImport(UIKit)
                        TerminalSessionView(model: model)
                        #else
                        Text(verbatim: model.title)
                        #endif
                    case .files(let model):
                        FolderBrowserView(model: model)
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
        return AgentListView(model: hosts.agentList, usage: hosts.claudeUsage, window: navigation, openInNewWindow: open) { route, sessionID in
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

    /// 版面圖卡片(選取中主機的 workspace)選了 Pane:Agent 在對話欄打開;終端機(shell pane)開在新視窗(不支援多視窗時不做事)。
    private func openLayoutTarget(_ target: PaneOpenTarget) {
        switch target {
        case .chat(let paneID):
            navigation.selectedChat = ChatRoute(host: hosts.selection, paneID: paneID)
        case .terminal(let paneID):
            guard supportsMultipleWindows else { return }
            openWindow(value: PaneWindow(kind: .terminal, host: hosts.selection, paneID: paneID, sessionID: nil, title: paneID))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // 選取中主機(#39):只決定新聊天開在哪裡與套用誰的主題;所有主機的 Agent 都在列表上。
        ToolbarItem(placement: Self.hostPlacement) {
            SelectedHostMenu(hosts: hosts)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Settings", systemImage: "gearshape") { navigation.sheet = .settings }
                    .accessibilityIdentifier("menu.settings")
                Button("Hosts", systemImage: "desktopcomputer") { navigation.sheet = .hosts }
                    .accessibilityIdentifier("menu.hosts")
                // 選取中主機的登入 Shell 與檔案(行為規格 F13;iPad 上也是推疊)。
                // 不包 Section:包了之後 XCUITest 找不到選單項目的 identifier。
                Button("Login Shell", systemImage: "apple.terminal") { hostTool = .loginShell(hosts.loginShell()) }
                    .accessibilityIdentifier("menu.loginShell")
                Button("Files", systemImage: "folder") { hostTool = .files(hosts.folderBrowser()) }
                    .accessibilityIdentifier("menu.files")
                Button("Member", systemImage: "person.crop.circle") { navigation.sheet = .member }
                    .accessibilityIdentifier("menu.member")
                if plus != nil {
                    Button("Purrdr Plus", systemImage: "bell.badge") { navigation.sheet = .plus }
                        .accessibilityIdentifier("menu.plus")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("toolbar.more")
        }
        // 「+」是主要動作(DESIGN.md:填色紅底),跟「⋯」分成兩個玻璃群組。
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("New Chat", systemImage: "plus") { navigation.sheet = .newChat }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("toolbar.newChat")
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

/// 從「⋯」選單推進來的主機工具。每次打開都是新的 model(新的 shell、從家目錄開始)。
enum HostTool: Hashable {
    case loginShell(LoginShellModel)
    case files(FolderBrowserModel)

    private var object: AnyObject {
        switch self {
        case .loginShell(let model): model
        case .files(let model): model
        }
    }

    static func == (a: HostTool, b: HostTool) -> Bool { a.object === b.object }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(object)) }
}

/// 新增對話的 sheet:model 在 sheet 開啟時建立一次(選取中主機),之後重繪不重建。
private struct NewChatSheet: View {
    @State private var model: NewChatModel
    let onCancel: () -> Void
    let onStarted: (CreatedWorkspace) -> Void

    init(model: @autoclosure () -> NewChatModel, onCancel: @escaping () -> Void, onStarted: @escaping (CreatedWorkspace) -> Void) {
        _model = State(wrappedValue: model())
        self.onCancel = onCancel
        self.onStarted = onStarted
    }

    var body: some View {
        NewChatView(model: model, onCancel: onCancel, onStarted: onStarted)
    }
}

/// 頂部的主機鈕：顯示選取中主機的圖示與名稱，選單裡切換選取中主機(#39、DESIGN.md)。
struct SelectedHostMenu: View {
    let hosts: HostsModel

    var body: some View {
        Menu {
            Picker(selection: selection) {
                Label("Demo", systemImage: HostIcon.default.symbol)
                    .tag(HostSelection.demo)
                ForEach(hosts.rows) { row in
                    Label(row.title, systemImage: row.icon.symbol)
                        .tag(HostSelection.host(row.id))
                }
            } label: {
                Text("Selected Host")
            }
            .accessibilityIdentifier("hostMenu.picker")
            Section {
                Text("New chats start on the selected host. Agents on every host stay in the list.")
            }
        } label: {
            Label {
                Text(verbatim: hosts.name(of: hosts.selection))
            } icon: {
                Image(systemName: hosts.selectionIcon.symbol)
            }
            .labelStyle(.titleAndIcon)
        }
        // 工具列的 Menu 不會把 accessibilityValue 帶給 VoiceOver,主機名放進 label。
        .accessibilityLabel(Text("Selected Host: \(hosts.name(of: hosts.selection))"))
        .accessibilityIdentifier("toolbar.host")
    }

    private var selection: Binding<HostSelection> {
        Binding { hosts.selection } set: { hosts.select($0) }
    }
}
