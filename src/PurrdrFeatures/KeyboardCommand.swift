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
    case toggleInspector
    case openInNewWindow
}

/// 選單項目停用條件需要的視窗狀態(#522)。純值，單元測試可直接組。
public struct KeyboardCommandContext: Equatable, Sendable {
    /// 有選取的聊天(對話或 Pane 終端機)。
    public var hasSelectedChat: Bool
    /// 選取的是 Agent 對話(Pane 終端機沒有 Inspector)。
    public var hasSelectedConversation: Bool
    /// 目前選的 tab。
    public var tab: TopLevelTab
    /// 視窗夠寬,Inspector 是右側欄(窄視窗是 sheet,沒有選單可切)。
    public var isWideWindow: Bool
    public var isInspectorShown: Bool
    public var supportsMultipleWindows: Bool

    public init(
        hasSelectedChat: Bool = false, hasSelectedConversation: Bool = false, tab: TopLevelTab = .chats,
        isWideWindow: Bool = true, isInspectorShown: Bool = false, supportsMultipleWindows: Bool = true
    ) {
        self.hasSelectedChat = hasSelectedChat
        self.hasSelectedConversation = hasSelectedConversation
        self.tab = tab
        self.isWideWindow = isWideWindow
        self.isInspectorShown = isInspectorShown
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
        case .settings: KeyboardShortcut(",", modifiers: .command)
        case .showChats: KeyboardShortcut("?", modifiers: [])
        case .showFiles: KeyboardShortcut("?", modifiers: [])
        case .showHosts: KeyboardShortcut("?", modifiers: [])
        case .showTraffic: KeyboardShortcut("?", modifiers: [])
        case .toggleInspector: KeyboardShortcut("?", modifiers: [])
        case .openInNewWindow: KeyboardShortcut("?", modifiers: [])
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
        case .toggleInspector: "Show Inspector"
        case .openInNewWindow: "Open in New Window"
        }
    }

    /// 選單項目的停用條件:不能用就停用、不隱藏(#522)。
    public func isEnabled(in context: KeyboardCommandContext) -> Bool {
        true
    }

    /// 選單項目在這個狀態下的名稱(Inspector 依開關顯示「Show／Hide Inspector」)。
    public func title(in context: KeyboardCommandContext) -> LocalizedStringKey {
        LocalizedStringKey(titleText(in: context))
    }

    /// `title(in:)` 的英文 key(測試用)。
    public func titleText(in context: KeyboardCommandContext) -> String {
        "Show Inspector"
    }

    /// 「顯示方式」選單的項目與順序(#522)。
    public static let viewMenu: [KeyboardCommand] = []
    /// 「Agent」選單的項目與順序。
    public static let agentMenu: [KeyboardCommand] = [.nextAgent, .previousAgent, .search, .openTerminal]

    /// 這個指令切到的 tab;不是切 tab 的指令為 `nil`。
    public var tab: TopLevelTab? { nil }
}
