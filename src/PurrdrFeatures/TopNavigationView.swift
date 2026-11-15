import SwiftUI

/// iPhone 頂層導覽(#37 故事 21):Agent 列表 + 工具列的「⋯」選單與「+」,其餘畫面以 sheet 開啟。
///
/// 不採 tab bar。導覽層只在這裡;Agent 列表本身(`AgentListView`)不知道有哪些 sheet。
public struct TopNavigationView: View {
    let navigation: TopNavigationModel
    let hosts: HostsModel
    let member: MemberModel
    let settings: SettingsModel
    /// Purrdr Plus(#28);`nil` 時選單不顯示。
    let plus: SubscriptionModel?
    /// 主機同步(#30);`nil` 時設定頁不顯示。
    let hostSync: HostSyncModel?
    @Environment(\.scenePhase) private var scenePhase

    public init(
        navigation: TopNavigationModel, hosts: HostsModel, member: MemberModel, settings: SettingsModel, plus: SubscriptionModel? = nil,
        hostSync: HostSyncModel? = nil
    ) {
        self.hostSync = hostSync
        self.navigation = navigation
        self.hosts = hosts
        self.member = member
        self.settings = settings
        self.plus = plus
    }

    public var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            // 選取中主機的 Agent 列表;換主機時整個列表重建(載入狀態、事件串流、搜尋字都重置，行為規格 F1.3)。
            AgentListView(model: hosts.agentList, actions: hosts.workspaceActions, usage: hosts.claudeUsage) { paneID, sessionID in
                hosts.conversation(paneID: paneID, sessionID: sessionID)
            } terminal: { paneID, title in
                hosts.terminal(paneID: paneID, title: title)
            }
            .id(hosts.selection)
                .toolbar { toolbar }
        }
        .sheet(item: $navigation.sheet) { sheet in
            switch sheet {
            case .hosts:
                HostListView(model: hosts, importURL: $navigation.pendingHostImport)
            case .settings:
                SettingsView(model: settings, member: member, plus: plus, hostSync: hostSync) { navigation.sheet = nil }
            case .member:
                // 會員畫面自帶 NavigationStack 與「完成」。
                MemberView(model: member, plus: plus)
            case .plus:
                if let plus {
                    PlusSheet(model: plus, member: member)
                }
            case .newChat:
                TopLevelSheetView(sheet: sheet) { navigation.sheet = nil }
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
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Settings", systemImage: "gearshape") { navigation.sheet = .settings }
                    .accessibilityIdentifier("menu.settings")
                Button("Hosts", systemImage: "desktopcomputer") { navigation.sheet = .hosts }
                    .accessibilityIdentifier("menu.hosts")
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

/// 頂層 sheet 的外殼：標題 + 「完成」。內容由各自的票補上(新增對話)。
struct TopLevelSheetView: View {
    let sheet: TopLevelSheet
    let done: () -> Void

    var body: some View {
        NavigationStack {
            placeholder
                .accessibilityIdentifier("sheet.\(sheet.rawValue)")
                .navigationTitle(sheet.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                            .accessibilityIdentifier("sheet.done")
                    }
                }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(sheet.title, systemImage: sheet.symbol)
    }
}

extension TopLevelSheet {
    var title: LocalizedStringKey {
        switch self {
        case .settings: "Settings"
        case .hosts: "Hosts"
        case .newChat: "New Chat"
        case .member: "Purrdr Member"
        case .plus: "Purrdr Plus"
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .hosts: "desktopcomputer"
        case .newChat: "plus.bubble"
        case .member: "person.crop.circle"
        case .plus: "bell.badge"
        }
    }
}
