import PurrdrFeatures
import SwiftUI
import Testing

/// 鍵盤快捷鍵的對應(#31、DESIGN.md:app 快捷鍵只用 Command;HIG 檢核清單 20.9)。
@Suite("鍵盤快捷鍵")
struct KeyboardCommandTests {
    @Test("每個快捷鍵都含 Command,而且不含 Control(Control 組合鍵在終端機聚焦時送往遠端)")
    func everyShortcutUsesCommandWithoutControl() {
        for command in KeyboardCommand.allCases {
            #expect(command.shortcut.modifiers.contains(.command), "\(command)")
            #expect(!command.shortcut.modifiers.contains(.control), "\(command)")
        }
    }

    @Test("快捷鍵不重複")
    func shortcutsAreUnique() {
        let keys = KeyboardCommand.allCases.map { "\($0.shortcut.key.character)|\($0.shortcut.modifiers.rawValue)" }
        #expect(Set(keys).count == keys.count)
    }

    /// iPadOS 的選單列「App 名稱 > Settings…」(Command-,)是系統自動產生、不能取代的項目,開的是 iOS「設定」app 裡這個 app 的頁面
    /// (HIG〈The menu bar〉:Reserve the YourAppName > Settings menu item for opening your app's page in iPadOS Settings;
    /// app 自己的設定用另一個項目接在它下面。DTS:You cannot replace the default Preferences or Settings menu item)。
    /// 實測 app 有「設定」頁後(第二次啟動起)系統會接走 Command-,,所以 App Settings… 不能用 Command-,。
    @Test("App Settings… 不用 Command-,(那是系統『設定』app 的捷徑)")
    func appSettingsDoesNotClaimSystemSettingsShortcut() {
        let shortcut = KeyboardCommand.settings.shortcut
        #expect(!(shortcut.key.character == "," && shortcut.modifiers == .command))
        #expect(shortcut.key.character == ",")
        #expect(shortcut.modifiers == [.command, .option])
    }

    @Test(
        "常用動作用系統慣例的鍵:Command-, 設定、Command-F 搜尋、Command-N 新增對話",
        arguments: [
            (KeyboardCommand.search, Character("f")),
            (.newChat, "n"),
        ]
    )
    func conventionalKeys(command: KeyboardCommand, key: Character) {
        #expect(command.shortcut.key.character == key)
        #expect(command.shortcut.modifiers == .command)
    }

    @Test("選單列不取代系統的 Settings… 項目,App Settings… 加在它後面")
    func appSettingsIsAddedAfterSystemSettingsItem() throws {
        let source = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "src/PurrdrFeatures/WindowViews.swift"), encoding: .utf8)
        #expect(!source.contains("CommandGroup(replacing: .appSettings)"), "取代 Settings 項目實測第二次啟動起被系統接走")
        #expect(source.contains("CommandGroup(after: .appSettings)"))
    }

    @Test("切換 Agent 用 Command-Option-方向鍵，不佔用 Command-[ ](系統的返回)")
    func agentSwitchingUsesOptionArrows() {
        #expect(KeyboardCommand.nextAgent.shortcut.key == .downArrow)
        #expect(KeyboardCommand.previousAgent.shortcut.key == .upArrow)
        #expect(KeyboardCommand.nextAgent.shortcut.modifiers == [.command, .option])
    }
}
