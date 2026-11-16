import SwiftUI

/// app 的鍵盤快捷鍵(#31)。只用 Command(DESIGN.md);終端機聚焦時 Control 組合鍵與 Esc 送往遠端。
public enum KeyboardCommand: CaseIterable, Sendable {
    case nextAgent
    case previousAgent
    case search
    case openTerminal
    case newChat
    case settings
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
        }
    }
}
