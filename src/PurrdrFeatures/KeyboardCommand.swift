import SwiftUI

/// app 的鍵盤快捷鍵(#31)。只用 Command(DESIGN.md);終端機聚焦時 Control 組合鍵與 Esc 送往遠端。
public enum KeyboardCommand: CaseIterable, Sendable {
    case nextAgent
    case previousAgent
    case search
    case openTerminal
    case newChat
    case settings
    case showChats
    case showFiles
    case showHosts
    case showTraffic
    case toggleConversationPanel
    case openInNewWindow
}

/// 選單項目停用條件需要的視窗狀態(#522)。純值，單元測試可直接組。
public struct KeyboardCommandContext: Equatable, Sendable {
    /// 有選取的聊天(對話或 Pane 終端機)。
    public var hasSelectedChat: Bool
    /// 選取的是 Agent 對話(Pane 終端機沒有用量與詳細資料面板)。
    public var hasSelectedConversation: Bool
    /// 目前選的 tab。
    public var tab: TopLevelTab
    /// 視窗夠寬(面板是 popover;窄視窗是 sheet)。目前不影響任何指令的啟用。
    public var isWideWindow: Bool
    public var supportsMultipleWindows: Bool

    public init(
        hasSelectedChat: Bool = false, hasSelectedConversation: Bool = false, tab: TopLevelTab = .chats,
        isWideWindow: Bool = true, supportsMultipleWindows: Bool = true
    ) {
        self.hasSelectedChat = hasSelectedChat
        self.hasSelectedConversation = hasSelectedConversation
        self.tab = tab
        self.isWideWindow = isWideWindow
        self.supportsMultipleWindows = supportsMultipleWindows
    }
}

extension KeyboardCommand {
    /// 對應的按鍵。不覆寫系統標準快捷鍵(Command-[ 是返回、Option-Command-T 是工具列)。
    public var shortcut: KeyboardShortcut {
        switch self {
        case .nextAgent: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .previousAgent: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .search: KeyboardShortcut("f", modifiers: .command)
        case .openTerminal: KeyboardShortcut("t", modifiers: [.command, .shift])
        case .newChat: KeyboardShortcut("n", modifiers: .command)
        case .settings: KeyboardShortcut(",", modifiers: [.command, .option])
        case .showChats: KeyboardShortcut("1", modifiers: .command)
        case .showFiles: KeyboardShortcut("2", modifiers: .command)
        case .showHosts: KeyboardShortcut("3", modifiers: .command)
        case .showTraffic: KeyboardShortcut("4", modifiers: .command)
        case .toggleConversationPanel: KeyboardShortcut("i", modifiers: [.command, .option])
        case .openInNewWindow: KeyboardShortcut("o", modifiers: [.command, .option])
        }
    }

    /// 選單與按住 Command 時的快捷鍵清單上顯示的名稱。
    public var title: LocalizedStringKey {
        switch self {
        case .nextAgent: "Next Agent"
        case .previousAgent: "Previous Agent"
        case .search: "Search"
        case .openTerminal: "Open Terminal"
        case .newChat: "New Chat"
        // 選單列的「Settings…」保留給系統的設定 app 頁面，app 內設定另列一項(HIG 檢核清單 20.9)。
        case .settings: "App Settings…"
        case .showChats: "Chats"
        case .showFiles: "Files"
        case .showHosts: "Hosts"
        case .showTraffic: "Traffic"
        case .toggleConversationPanel: "Show Usage & Context"
        case .openInNewWindow: "Open in New Window"
        }
    }

    /// 選單項目的停用條件:不能用就停用、不隱藏(#522)。
    public func isEnabled(in context: KeyboardCommandContext) -> Bool {
        switch self {
        case .openInNewWindow: context.hasSelectedChat && context.supportsMultipleWindows
        case .toggleConversationPanel: context.tab == .chats && context.hasSelectedConversation
        default: true
        }
    }

    /// 選單項目在這個狀態下的名稱。
    public func title(in context: KeyboardCommandContext) -> LocalizedStringKey {
        LocalizedStringKey(titleText(in: context))
    }

    /// `title(in:)` 的英文 key(測試用)。
    public func titleText(in context: KeyboardCommandContext) -> String {
        return switch self {
        case .showChats: "Chats"
        case .showFiles: "Files"
        case .showHosts: "Hosts"
        case .showTraffic: "Traffic"
        case .toggleConversationPanel: "Show Usage & Context"
        case .openInNewWindow: "Open in New Window"
        case .nextAgent: "Next Agent"
        case .previousAgent: "Previous Agent"
        case .search: "Search"
        case .openTerminal: "Open Terminal"
        case .newChat: "New Chat"
        case .settings: "App Settings…"
        }
    }

    /// 「顯示方式」選單的項目與順序(#522)。
    public static let viewMenu: [KeyboardCommand] = [.showChats, .showFiles, .showHosts, .showTraffic, .toggleConversationPanel]
    /// 「Agent」選單的項目與順序。
    public static let agentMenu: [KeyboardCommand] = [.nextAgent, .previousAgent, .search, .openTerminal, .openInNewWindow]

    /// 這個指令切到的 tab;不是切 tab 的指令為 `nil`。
    public var tab: TopLevelTab? {
        switch self {
        case .showChats: .chats
        case .showFiles: .files
        case .showHosts: .hosts
        case .showTraffic: .traffic
        default: nil
        }
    }
}
