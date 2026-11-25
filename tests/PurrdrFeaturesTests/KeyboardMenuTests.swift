import PurrdrFeatures
import SwiftUI
import Testing

/// iPad 選單列(#522):顯示方式、Agent 選單的項目、快捷鍵與停用條件。
@Suite("iPad 選單指令")
struct KeyboardMenuTests {
    private func key(_ c: KeyboardCommand) -> String {
        "\(c.shortcut.key.character)|\(c.shortcut.modifiers.rawValue)"
    }

    @Test("顯示方式選單:聊天、檔案、主機、流量依序是 Command-1 到 4,再來 Option-Command-I")
    func viewMenuItems() {
        #expect(KeyboardCommand.viewMenu == [.showChats, .showFiles, .showHosts, .showTraffic, .toggleInspector])
        let digits: [(KeyboardCommand, Character, TopLevelTab)] = [
            (.showChats, "1", .chats), (.showFiles, "2", .files), (.showHosts, "3", .hosts), (.showTraffic, "4", .traffic),
        ]
        for (command, digit, tab) in digits {
            #expect(command.shortcut.key.character == digit, "\(command)")
            #expect(command.shortcut.modifiers == .command, "\(command)")
            #expect(command.tab == tab, "\(command)")
        }
        #expect(KeyboardCommand.toggleInspector.shortcut.key.character == "i")
        #expect(KeyboardCommand.toggleInspector.shortcut.modifiers == [.command, .option])
        #expect(KeyboardCommand.toggleInspector.tab == nil)
    }

    @Test("Agent 選單:加上在新視窗開啟(Option-Command-O),既有項目不變")
    func agentMenuItems() {
        #expect(KeyboardCommand.agentMenu == [.nextAgent, .previousAgent, .search, .openTerminal, .openInNewWindow])
        #expect(KeyboardCommand.openInNewWindow.shortcut.key.character == "o")
        #expect(KeyboardCommand.openInNewWindow.shortcut.modifiers == [.command, .option])
    }

    @Test("既有快捷鍵不變")
    func existingShortcutsUnchanged() {
        #expect(key(.newChat) == "n|\(EventModifiers.command.rawValue)")
        #expect(key(.search) == "f|\(EventModifiers.command.rawValue)")
        #expect(key(.openTerminal) == "t|\(EventModifiers([.command, .shift]).rawValue)")
        #expect(key(.settings) == ",|\(EventModifiers.command.rawValue)")
    }

    @Test("快捷鍵不與「新視窗」(Option-Command-N)重複")
    func noClashWithNewWindow() {
        let newWindow = "n|\(EventModifiers([.command, .option]).rawValue)"
        #expect(!KeyboardCommand.allCases.map(key).contains(newWindow))
    }

    @Test("在新視窗開啟:沒有選取的聊天、或不支援多視窗時停用")
    func openInNewWindowEnabled() {
        #expect(!KeyboardCommand.openInNewWindow.isEnabled(in: KeyboardCommandContext(hasSelectedChat: false)))
        #expect(KeyboardCommand.openInNewWindow.isEnabled(in: KeyboardCommandContext(hasSelectedChat: true)))
        #expect(!KeyboardCommand.openInNewWindow.isEnabled(
            in: KeyboardCommandContext(hasSelectedChat: true, supportsMultipleWindows: false)))
    }

    @Test("Inspector:要在聊天 tab、寬視窗、選了 Agent 對話才能用,其餘停用")
    func inspectorEnabled() {
        let ready = KeyboardCommandContext(hasSelectedChat: true, hasSelectedConversation: true)
        #expect(KeyboardCommand.toggleInspector.isEnabled(in: ready))
        var c = ready
        c.hasSelectedConversation = false
        #expect(!KeyboardCommand.toggleInspector.isEnabled(in: c))
        c = ready
        c.tab = .hosts
        #expect(!KeyboardCommand.toggleInspector.isEnabled(in: c))
        c = ready
        c.isWideWindow = false
        #expect(!KeyboardCommand.toggleInspector.isEnabled(in: c))
    }

    @Test("切 tab 的項目一律可用;Inspector 標題依開關顯示或隱藏")
    func tabsAlwaysEnabledAndInspectorTitle() {
        for command in [KeyboardCommand.showChats, .showFiles, .showHosts, .showTraffic] {
            #expect(command.isEnabled(in: KeyboardCommandContext()))
        }
        #expect(KeyboardCommand.toggleInspector.titleText(in: KeyboardCommandContext(isInspectorShown: false)) == "Show Inspector")
        #expect(KeyboardCommand.toggleInspector.titleText(in: KeyboardCommandContext(isInspectorShown: true)) == "Hide Inspector")
    }
}
