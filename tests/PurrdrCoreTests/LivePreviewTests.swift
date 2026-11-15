import PurrdrCore
import Testing

/// 即時預覽(行為規格 F5.11、§4.8、R-Q11):從 working 的 pane 可見畫面擷取 agent 正在寫的散文。
/// 畫面是依規格手寫的(沒有可錄的真實 working 畫面),格式見 `Fixtures/screens/` 的說明。
/// 錯的預覽會被當成 agent 的回答，所以拿不準就不顯示。
@Suite("即時預覽")
struct LivePreviewTests {
    static let separator = String(repeating: "─", count: 60)

    /// Claude 工作中：散文、spinner 行、輸入框、頁尾。
    static let claudeWorking = """
        ⏺ Read 2 files

        ⏺ The cache expiry is stored in seconds, but the settings screen
          writes minutes, so every forecast looks stale after a minute.

        ✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)

        \(separator)
        ❯
        \(separator)
          ⏵⏵ accept edits on (shift+tab to cycle)

        """

    @Test("Claude:從 spinner 錨點往上收散文，去掉前導 ⏺、併成一段")
    func claudeProseAboveSpinner() {
        #expect(LivePreview.extract(screen: Self.claudeWorking) ==
            "The cache expiry is stored in seconds, but the settings screen writes minutes, so every forecast looks stale after a minute.")
    }

    @Test("ANSI 跳脫序列先剝掉(含 ESC 字元的 CSI、OSC);框線只修剪兩端")
    func stripsEscapesAndBorders() {
        let screen = """
            │ \u{1B}[1m⏺ [TODO] list is longer than the screen, so I'll page it.\u{1B}[0m │
            \u{1B}]0;title\u{07}
            ✶ Working… (esc to interrupt)
            """
        #expect(LivePreview.extract(screen: screen) == "[TODO] list is longer than the screen, so I'll page it.")
    }

    @Test("錨點之上是工具輸出(⎿)→ 不顯示")
    func toolOutputIsNotPreview() {
        let screen = """
            ⏺ Bash(swift test)
              ⎿  Building for debugging and running every test target now

            ✻ Running… (esc to interrupt)
            ❯
            """
        #expect(LivePreview.extract(screen: screen) == nil)
    }

    @Test("不到 20 字不顯示(錯的預覽比沒有更糟)")
    func shortTextIsNotPreview() {
        let screen = """
            ⏺ Looking now.

            ✻ Pondering… (esc to interrupt)
            """
        #expect(LivePreview.extract(screen: screen) == nil)
    }

    @Test("沒有 spinner 時以狀態行(esc to interrupt／tokens)當錨點;chrome 行略過")
    func statusLineAnchor() {
        let screen = """
            • Updating the README so the install steps match the new script.

            ctx: 41% used
            Working (8s • esc to interrupt)
            ›
            """
        #expect(LivePreview.extract(screen: screen) == "Updating the README so the install steps match the new script.")
    }

    @Test("Codex:錨點前最後一個 • 行是 Ran／Explored 這類工具 → 不顯示")
    func codexToolLineIsNotPreview() {
        let screen = """
            • Ran swift build --product notes-cli --configuration release

            Working (3s • esc to interrupt)
            ›
            """
        #expect(LivePreview.extract(screen: screen) == nil)
    }

    @Test("往上遇到使用者的 prompt(❯ 文字)就停;只收到 prompt → 不顯示")
    func stopsAtUserPrompt() {
        let screen = """
            ❯ please refactor the forecast cache to use minutes everywhere

            ✻ Pondering… (esc to interrupt)
            """
        #expect(LivePreview.extract(screen: screen) == nil)
    }

    @Test("閒置畫面(沒有錨點只有輸入框)上方的舊回覆也照規則取;空畫面 → 不顯示")
    func emptyScreen() {
        #expect(LivePreview.extract(screen: "") == nil)
        #expect(LivePreview.extract(screen: "\n\n❯ \n") == nil)
    }
}
