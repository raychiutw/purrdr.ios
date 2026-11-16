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

    @Test(
        "常用動作用系統慣例的鍵:Command-, 設定、Command-F 搜尋、Command-N 新增對話",
        arguments: [
            (KeyboardCommand.settings, Character(",")),
            (.search, "f"),
            (.newChat, "n"),
        ]
    )
    func conventionalKeys(command: KeyboardCommand, key: Character) {
        #expect(command.shortcut.key.character == key)
        #expect(command.shortcut.modifiers == .command)
    }

    @Test("切換 Agent 用 Command-Option-方向鍵，不佔用 Command-[ ](系統的返回)")
    func agentSwitchingUsesOptionArrows() {
        #expect(KeyboardCommand.nextAgent.shortcut.key == .downArrow)
        #expect(KeyboardCommand.previousAgent.shortcut.key == .upArrow)
        #expect(KeyboardCommand.nextAgent.shortcut.modifiers == [.command, .option])
    }
}
