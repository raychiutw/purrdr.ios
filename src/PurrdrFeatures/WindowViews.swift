import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

// MARK: - 側欄：主機與 workspace

/// iPad 三欄的第一欄(#31):主機(點了即選取)與選取中主機的 workspace(點了篩選 Agent 列表)。
/// 所有主機的 Agent 都在列表上(#39);選取中主機決定新聊天開在哪裡，以及這裡列出誰的 workspace。
///
/// 只有兩層(HIG Sidebars)。workspace 列尾的版面圖按鈕：指標停留預覽、點了釘住浮動卡片(#37 故事 22)。
struct WindowSidebar: View {
    let hosts: HostsModel
    let navigation: TopNavigationModel

    private enum Item: Hashable {
        case allWorkspaces
        case workspace(String)
    }

    var body: some View {
        List(selection: selection) {
            Section("Hosts") {
                ForEach(hosts.rows) { row in
                    hostButton(.host(row.id), title: row.title, icon: row.icon, isSelected: row.isSelected)
                }
                hostButton(.demo, title: String(localized: "Demo"), icon: .default, isSelected: hosts.selection == .demo)
                    .accessibilityIdentifier("sidebar.host.demo")
            }
            Section("Workspaces") {
                Label("All Workspaces", systemImage: "square.grid.2x2")
                    .tag(Item.allWorkspaces)
                    .accessibilityIdentifier("sidebar.allWorkspaces")
                ForEach(workspaces) { workspace in
                    WorkspaceSidebarRow(workspace: workspace, card: navigation.layoutCard)
                        .tag(Item.workspace(workspace.id))
                }
            }
        }
        .navigationTitle(hostTitle)
        .accessibilityIdentifier("sidebar")
    }

    private var workspaces: [Workspace] {
        hosts.agentList.snapshot(for: hosts.selection)?.workspaces ?? []
    }

    /// 側欄標題是選取中主機的名稱：多個視窗時能分辨(不用 app 名稱，HIG Toolbars)。
    private var hostTitle: String {
        hosts.selectedHost?.name ?? String(localized: "Demo")
    }

    private var selection: Binding<Item?> {
        Binding {
            navigation.workspaceFilter.map(Item.workspace) ?? .allWorkspaces
        } set: { item in
            if case .workspace(let id) = item {
                navigation.workspaceFilter = id
            } else {
                navigation.workspaceFilter = nil
            }
        }
    }

    private func hostButton(_ selection: HostSelection, title: String, icon: HostIcon, isSelected: Bool) -> some View {
        Button {
            guard hosts.selection != selection else { return }
            hosts.select(selection)
        } label: {
            HStack {
                // 主機圖示同主機鈕與列表的主機名標示(#39)。
                HostMenuLabel(title, icon: icon)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressableRow(cornerRadius: 8))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 側欄的一個 workspace:名稱 + 版面圖按鈕。
private struct WorkspaceSidebarRow: View {
    let workspace: Workspace
    let card: LayoutCardModel

    var body: some View {
        HStack {
            Label(workspace.label ?? workspace.id, systemImage: "folder")
                .accessibilityIdentifier("sidebar.workspace.\(workspace.id)")
            Spacer()
            // 觸控目標 ≥ 44×44 pt(frame 放在 label 裡才會撐大可點範圍,#35 iPad audit)。
            Button {
                card.tap(workspace.id)
            } label: {
                Label("Show Layout", systemImage: "rectangle.split.3x1")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .onHover { inside in
                Task { await card.pointer(overButton: workspace.id, isInside: inside) }
            }
            .accessibilityIdentifier("sidebar.layout.\(workspace.id)")
        }
        // 名稱與版面圖按鈕是兩個元素(VoiceOver、Full Keyboard Access 都能單獨到按鈕)。
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 版面圖浮動卡片

/// iPad 的版面圖浮動卡片(#37 故事 22、行為規格 F4):浮在 Agent 列表上方靠前緣，寬 340、最高 520pt。
/// 釘住時點卡片以外的地方、按「關閉」或 Esc 關閉。
struct LayoutCardOverlay: View {
    let card: LayoutCardModel
    let snapshot: HostSnapshot?
    let onChoose: (PaneOpenTarget) -> Void

    var body: some View {
        if let workspaceID = card.workspaceID {
            ZStack(alignment: .topLeading) {
                if card.isPinned {
                    // 點背景關閉。
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { card.close() }
                        .accessibilityHidden(true)
                }
                LayoutCard(card: card, workspaceID: workspaceID, snapshot: snapshot, onChoose: onChoose)
                    .id(workspaceID)
                    .padding(12)
            }
        }
    }
}

private struct LayoutCard: View {
    let card: LayoutCardModel
    let workspaceID: String
    let onChoose: (PaneOpenTarget) -> Void
    /// 開啟當下的版面，不即時更新(行為規格 F4)。
    @State private var layout: SpacesLayout?
    private let label: String

    init(card: LayoutCardModel, workspaceID: String, snapshot: HostSnapshot?, onChoose: @escaping (PaneOpenTarget) -> Void) {
        self.card = card
        self.workspaceID = workspaceID
        self.onChoose = onChoose
        _layout = State(initialValue: snapshot.flatMap { SpacesLayout(snapshot: $0, workspaceID: workspaceID) })
        label = snapshot?.workspaces.first { $0.id == workspaceID }?.label ?? workspaceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close", systemImage: "xmark") { card.close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("layoutCard.close")
            }
            .padding([.horizontal, .top])
            SpacesLayoutContent(layout: layout, maxColumns: 1) { target in
                card.close()
                onChoose(target)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .onHover { inside in
            Task { await card.pointer(overCard: inside) }
        }
        // 在卡片上按下即釘住。
        .simultaneousGesture(TapGesture().onEnded { card.pin() })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layoutCard")
    }
}

// MARK: - 對話欄

/// 三欄的對話欄：選取的 Agent 對話(可再推入它的終端機);沒選時「選一個對話」(行為規格 F20)。
struct WindowDetail: View {
    let hosts: HostsModel
    let navigation: TopNavigationModel

    var body: some View {
        NavigationStack {
            if let route = navigation.selectedChat, let title = hosts.agentList.terminalTitle(of: route) {
                // agent 以外的 pane(Spaces 的終端機列、版面圖的終端機方塊):開它的 Pane 終端機(#40)。
                PaneTerminalScreen(model: hosts.terminal(route, title: title))
            } else if let route = navigation.selectedChat {
                ConversationScreen(
                    model: hosts.conversation(route, sessionID: hosts.agentList.sessionID(of: route)),
                    makeTerminal: { hosts.terminal(ChatRoute(host: route.host, paneID: $0), title: $1) }, window: navigation, route: route,
                    otherNeedsYou: hosts.agentList.needsYouCount(excluding: route))
            } else {
                ContentUnavailableView("Select a Chat", systemImage: "bubble.left.and.bubble.right")
                    .accessibilityIdentifier("detail.empty")
            }
        }
        // 換一個聊天就整個重建(對話 model、推入的終端機)。
        .id(navigation.selectedChat)
    }
}

// MARK: - 在新視窗開啟

/// 開在新視窗的 Agent 對話或 Pane 終端機(#31)。任何一台主機的都可以：每台主機各自連線(#39),跟選取中主機無關。
/// 視窗的主機已被移除時(例：還原視窗時那台主機已刪掉)顯示說明。
public struct PaneWindowView: View {
    let window: PaneWindow
    let hosts: HostsModel

    public init(window: PaneWindow, hosts: HostsModel) {
        self.window = window
        self.hosts = hosts
    }

    public var body: some View {
        NavigationStack {
            if let route = window.route(hostIDs: hosts.listedHostIDs) {
                PaneWindowContent(window: window, route: route, hosts: hosts)
            } else {
                ContentUnavailableView(
                    "Host Not Available",
                    systemImage: "desktopcomputer",
                    description: Text("This window’s host was removed from this device.")
                )
                .navigationTitle(window.title)
            }
        }
        // 跟主視窗一樣套用選取中主機的主題(#23)。
        .selectedHostTheme(hosts)
    }
}

private struct PaneWindowContent: View {
    let window: PaneWindow
    let route: ChatRoute
    let hosts: HostsModel

    var body: some View {
        switch window.kind {
        case .chat:
            ConversationScreen(
                model: hosts.conversation(route, sessionID: window.sessionID),
                makeTerminal: { hosts.terminal(ChatRoute(host: route.host, paneID: $0), title: $1) })
            // 新視窗開著的聊天也記開啟時間、不算未讀(#41;每個視窗各算一次)。
            .onAppear { hosts.agentList.chatAppeared(route) }
            .onDisappear { hosts.agentList.chatDisappeared(route) }
        case .terminal:
            PaneTerminalScreen(model: hosts.terminal(route, title: window.title))
        }
    }
}

// MARK: - 鍵盤快捷鍵(選單列)

/// 有焦點的視窗執行快捷鍵的入口(每個視窗一份導覽狀態)。
public struct WindowCommands {
    let perform: @MainActor (KeyboardCommand) -> Void
    /// 這個視窗的版面圖浮動卡片開著(釘住或預覽)。開著時選單才有 Esc「關閉版面圖」。
    var isLayoutCardShown = false
    var closeLayoutCard: @MainActor () -> Void = {}
}

extension FocusedValues {
    @Entry public var windowCommands: WindowCommands?
}

/// app 的選單列與快捷鍵(#31,HIG 檢核清單 20.9)。作用在有焦點的視窗。
///
/// - 「新增對話」用 Command-N(系統慣例的「新增」),「新視窗」改用 Option-Command-N(同「郵件」)。
/// - 選單列的「Settings…」保留給系統的設定 app 頁面(拿掉它預設的 Command-,);app 內設定另列「App Settings…」(Command-,)。
/// - 選單裡的每個動作在畫面上也都找得到(列表工具列、對話標題列的終端機鈕、搜尋欄)。
public struct PurrdrCommands: Commands {
    @FocusedValue(\.windowCommands) private var window
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    public init() {}

    /// 主視窗(三欄)的 `WindowGroup` id。
    public static let mainWindowID = "main"

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            button(.newChat)
            Button("New Window") { openWindow(id: Self.mainWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        // 系統的「Settings…」預設也用 Command-,(同一個快捷鍵兩項會讓選單建立失敗而 crash):
        // 換成不帶快捷鍵、一樣打開系統設定 app 的項目，Command-, 給 app 內設定。
        CommandGroup(replacing: .appSettings) {
            #if canImport(UIKit)
            Button("Settings…") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            #endif
            button(.settings)
        }
        CommandMenu("Agents") {
            button(.nextAgent)
            button(.previousAgent)
            Divider()
            button(.search)
            button(.openTerminal)
            // Esc 關掉版面圖卡片(行為規格 F20)。只在卡片開著時才有，否則 Esc 要留給終端機送往遠端。
            if window?.isLayoutCardShown == true {
                Divider()
                Button("Close Layout") { window?.closeLayoutCard() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    private func button(_ command: KeyboardCommand) -> some View {
        Button(command.title) { window?.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(window == nil)
    }
}
