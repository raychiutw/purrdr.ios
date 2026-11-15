import SwiftUI

/// iPhone 頂層導覽(#37 故事 21):Agent 列表 + 工具列的「⋯」選單與「+」,其餘畫面以 sheet 開啟。
///
/// 不採 tab bar。導覽層只在這裡;Agent 列表本身(`AgentListView`)不知道有哪些 sheet。
public struct TopNavigationView: View {
    let navigation: TopNavigationModel
    let agentList: AgentListModel
    let workspaceActions: WorkspaceActionsModel
    /// 建立某個 Agent 的對話 model(pane id、列表看到的 session)。
    let conversation: @MainActor (String, String?) -> ConversationModel
    /// 建立某個 Pane 的終端機 model(pane id、標題)。
    let terminal: (@MainActor (String, String) -> PaneTerminalModel)?

    public init(
        navigation: TopNavigationModel, agentList: AgentListModel, workspaceActions: WorkspaceActionsModel,
        conversation: @escaping @MainActor (_ paneID: String, _ sessionID: String?) -> ConversationModel,
        terminal: (@MainActor (_ paneID: String, _ title: String) -> PaneTerminalModel)? = nil
    ) {
        self.navigation = navigation
        self.agentList = agentList
        self.workspaceActions = workspaceActions
        self.conversation = conversation
        self.terminal = terminal
    }

    public var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            AgentListView(model: agentList, actions: workspaceActions, conversation: conversation, terminal: terminal)
                .toolbar { toolbar }
        }
        .sheet(item: $navigation.sheet) { sheet in
            TopLevelSheetView(sheet: sheet) { navigation.sheet = nil }
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

/// 頂層 sheet 的外殼：標題 + 「完成」。內容由各自的票補上(設定 #32、主機 #10)。
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
        }
    }

    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .hosts: "desktopcomputer"
        case .newChat: "plus.bubble"
        }
    }
}
