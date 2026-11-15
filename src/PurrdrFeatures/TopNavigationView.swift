import SwiftUI

/// iPhone 頂層導覽(#37 故事 21):Agent 列表 + 工具列的「⋯」選單與「+」,其餘畫面以 sheet 開啟。
///
/// 不採 tab bar。導覽層只在這裡;Agent 列表本身(`AgentListView`)不知道有哪些 sheet。
public struct TopNavigationView: View {
    let navigation: TopNavigationModel
    let agentList: AgentListModel
    /// 建立某個 Agent 的對話 model(pane id、列表看到的 session)。
    let conversation: @MainActor (String, String?) -> ConversationModel

    public init(
        navigation: TopNavigationModel, agentList: AgentListModel,
        conversation: @escaping @MainActor (_ paneID: String, _ sessionID: String?) -> ConversationModel
    ) {
        self.navigation = navigation
        self.agentList = agentList
        self.conversation = conversation
    }

    public var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            AgentListView(model: agentList, conversation: conversation)
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

    @ViewBuilder
    private var placeholder: some View {
        switch sheet {
        case .settings:
            SettingsForm()
        case .hosts, .newChat:
            ContentUnavailableView(sheet.title, systemImage: sheet.symbol)
        }
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

/// 設定(目前只有硬體鍵盤;完整設定頁在 #32)。
struct SettingsForm: View {
    @AppStorage(ComposerSettings.returnSendsKey) private var returnSends = true

    var body: some View {
        Form {
            Section {
                Toggle("Return Key Sends", isOn: $returnSends)
                    .accessibilityIdentifier("settings.returnSends")
            } header: {
                Text("Hardware Keyboard")
            } footer: {
                Text("When off, Return adds a new line. Command-Return always sends, and Shift-Return always adds a new line.")
            }
        }
    }
}
