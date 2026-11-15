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
    /// 從「⋯」選單推進來的主機工具(登入 Shell、檔案瀏覽)。
    @State private var hostTool: HostTool?

    public init(
        navigation: TopNavigationModel, hosts: HostsModel, member: MemberModel, settings: SettingsModel, plus: SubscriptionModel? = nil
    ) {
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
        }
        .sheet(item: $navigation.sheet) { sheet in
            switch sheet {
            case .hosts:
                HostListView(model: hosts)
            case .settings:
                SettingsView(model: settings, member: member, plus: plus) { navigation.sheet = nil }
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
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
