import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

// MARK: - 對話欄

/// 兩欄的對話欄：選取的 Agent 對話(可再推入它的終端機);沒選時「選一個對話」(行為規格 F20)。
struct WindowDetail: View {
    let hosts: HostsModel
    let navigation: TopNavigationModel
    /// 寬視窗時帳號頭像掛在這一欄的工具列右側(最右邊那欄,視窗右上角;#520);`nil` 時由列表頂列放。
    var account: AnyView?

    var body: some View {
        NavigationStack {
            WindowDetailContent(hosts: hosts, navigation: navigation, route: navigation.selectedChat)
                .appNavigationBackground()
                .accountToolbarItem(account)
        }
        // 換一個聊天就整個重建(對話 model、推入的終端機)。
        .id(navigation.selectedChat)
    }
}

/// 選取的聊天內容(不含導覽層):寬視窗放在對話欄的 `NavigationStack`,窄視窗是 Agent 列表推入的目的地。
struct WindowDetailContent: View {
    let hosts: HostsModel
    let navigation: TopNavigationModel
    /// 顯示的聊天。窄視窗返回時 `selectedChat` 先清成 `nil`,轉場中推入的畫面要繼續顯示原本那個,所以由呼叫端傳入。
    let route: ChatRoute?

    var body: some View {
        if let route, let title = hosts.agentList.terminalTitle(of: route) {
            // agent 以外的 pane(Spaces 的終端機列、版面圖的終端機方塊):開它的 Pane 終端機(#40)。
            PaneTerminalScreen(model: hosts.terminal(route, title: title))
        } else if let route {
            ConversationScreen(
                model: hosts.conversation(route, sessionID: hosts.agentList.sessionID(of: route)),
                makeTerminal: { hosts.terminal(ChatRoute(host: route.host, paneID: $0), title: $1) }, window: navigation, route: route,
                layoutSnapshot: { hosts.agentList.snapshot(for: route.host) },
                openLayoutTarget: { target in
                    switch target {
                    case .chat(let paneID), .terminal(let paneID): navigation.selectedChat = ChatRoute(host: route.host, paneID: paneID)
                    }
                })
                .environment(\.usageHost, route.host)
        } else {
            ContentUnavailableView("Select a Chat", systemImage: "bubble.left.and.bubble.right")
                .accessibilityIdentifier("detail.empty")
        }
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
            Group {
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
            .appNavigationBackground()
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
            .environment(\.usageHost, route.host)
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
    /// 選單項目停用條件與標題要的視窗狀態(#522)。
    var context = KeyboardCommandContext()
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

    /// 主視窗(兩欄)的 `WindowGroup` id。
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
        // 「顯示方式」:系統「View」選單的最前面(#522)。項目不顯示圖示(iPadOS 27 預設)。
        CommandGroup(before: .toolbar) {
            ForEach(KeyboardCommand.viewMenu, id: \.self) { button($0) }
            Divider()
        }
        CommandMenu("Agents") {
            button(.nextAgent)
            button(.previousAgent)
            Divider()
            button(.search)
            button(.openTerminal)
            button(.openInNewWindow)
        }
    }

    private func button(_ command: KeyboardCommand) -> some View {
        let context = window?.context ?? KeyboardCommandContext()
        return Button(command.title(in: context)) { window?.perform(command) }
            .keyboardShortcut(command.shortcut)
            .disabled(window == nil || !command.isEnabled(in: context))
    }
}

// MARK: - 帳號頭像(寬視窗,#520)

/// 最右邊那欄工具列 trailing 的帳號頭像。iOS 27 起用釘住的 trailing(空間不夠也不收進溢出選單),iOS 26 退回一般 trailing。
/// 頭像自己就是玻璃圓鈕(同共用頂列),所以工具列不再疊一層底(`sharedBackgroundVisibility(.hidden)`);iOS 27 另外拿掉工具列項目的內容邊距,
/// 讓圓鈕貼滿。
struct AccountToolbarItem: ToolbarContent {
    let account: AnyView

    var body: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27, *) {
            ToolbarItem(placement: .topBarPinnedTrailing) { account }
                .sharedBackgroundVisibility(.hidden)
                .contentMarginsRemoved()
        } else {
            ToolbarItem(placement: .topBarTrailing) { account }
                .sharedBackgroundVisibility(.hidden)
        }
        #else
        ToolbarItem(placement: .automatic) { account }
        #endif
    }
}

extension View {
    /// 放上帳號頭像;`nil` 時不加(窄視窗,頭像在列表頂列)。
    func accountToolbarItem(_ account: AnyView?) -> some View {
        toolbar {
            if let account { AccountToolbarItem(account: account) }
        }
    }
}
