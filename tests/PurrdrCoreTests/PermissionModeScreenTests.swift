import PurrdrCore
import Testing

/// 從 Pane 畫面認權限模式、輪替順序(#306)。畫面是依 Claude Code 輸入框下一行的標示手寫的最小內容。
@Suite("權限模式")
struct PermissionModeScreenTests {
    static func screen(footer: String) -> String {
        "╭──────────────╮\n│ > ▌          │\n╰──────────────╯\n  \(footer)\n"
    }

    @Test(
        "從輸入框下方標示認出模式",
        arguments: [
            ("⏵⏵ accept edits on (shift+tab to cycle)", AgentPermissionMode.acceptEdits),
            ("⏸ plan mode on (shift+tab to cycle)", .plan),
            ("⏵⏵ bypass permissions on (shift+tab to cycle)", .bypassPermissions),
            ("? for shortcuts", .normal),
            ("⏵⏵ accept edits on (shift+tab to cycle) · esc to interrupt", .acceptEdits),
            ("esc to interrupt", .normal),
        ]
    )
    func parsesFooter(footer: String, expected: AgentPermissionMode) {
        #expect(PermissionModeScreen.parse(Self.screen(footer: footer)) == expected)
    }

    @Test("不是輸入畫面(沒有任何標示)認不出,回 nil")
    func unknownScreen() {
        #expect(PermissionModeScreen.parse("$ ls\nfile.txt\n") == nil)
    }

    @Test("點一下的輪替:一般 → 接受編輯 → Plan → 一般;略過權限回到一般")
    func cycleOrder() {
        #expect(AgentPermissionMode.normal.next() == .acceptEdits)
        #expect(AgentPermissionMode.acceptEdits.next() == .plan)
        #expect(AgentPermissionMode.plan.next() == .normal)
        #expect(AgentPermissionMode.bypassPermissions.next() == .normal)
    }
}
