import SwiftUI

/// iPhone 頂層導覽(#37 故事 21):Agent 列表 + 工具列的「⋯」選單與「+」,其餘畫面以 sheet 開啟。
///
/// 不採 tab bar。導覽層只在這裡;Agent 列表本身(`AgentListView`)不知道有哪些 sheet。
public struct TopNavigationView: View {
    let navigation: TopNavigationModel
    let hosts: HostsModel
    let member: MemberModel

    public init(navigation: TopNavigationModel, hosts: HostsModel, member: MemberModel) {
        self.navigation = navigation
        self.hosts = hosts
        self.member = member
    }

    public var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            // 選取中主機的 Agent 列表;換主機時整個列表重建(載入狀態、事件串流、搜尋字都重置，行為規格 F1.3)。
            AgentListView(model: hosts.agentList, actions: hosts.workspaceActions) { paneID, sessionID in
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
                HostListView(model: hosts)
            case .member:
                // 會員畫面自帶 NavigationStack 與「完成」。
                MemberView(model: member)
            case .settings, .newChat:
                TopLevelSheetView(sheet: sheet) { navigation.sheet = nil }
            }
        }
        // 冷啟動與從背景回來的深層連結都會走到這裡。
        .onOpenURL { navigation.open($0) }
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

/// 頂層 sheet 的外殼：標題 + 「完成」。內容由各自的票補上(設定 #32)。
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
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .hosts: "desktopcomputer"
        case .newChat: "plus.bubble"
        case .member: "person.crop.circle"
        }
    }
}
