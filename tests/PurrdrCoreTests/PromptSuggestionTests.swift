import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Claude Code 的建議提示詞(prompt suggestion,#121、#122)。
///
/// 畫面是 `pane.read`(visible、40 行、ANSI)的真實錄製:2026-11-17,Claude Code 2.1.326(Haiku 5.5)、herdr 0.9.5,
/// 作者 Mac 上自建的 `purrdr-test` workspace(見 `Fixtures/README.md`)。錄到的事實(判斷依據):
///
/// - 輸入列以 `❯` + NBSP(U+00A0)開頭;對話中已送出的 prompt 是 `❯` + 一般空白(加背景色)。
/// - 建議是 `ESC[2m`(SGR 2 dim)的文字;使用者打的字沒有任何 SGR 屬性。
/// - session 剛開時輸入列也有 dim 文字，但一律是 `Try "…"` 的形式(引號包住、太長在引號內以 `…` 截斷)。
@Suite("建議提示詞")
struct PromptSuggestionTests {
    static func screen(_ name: String) -> String {
        let line = Fixtures.data("pane.read.ansi.\(name).ndjson")
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let read = (object?["result"] as? [String: Any])?["read"] as? [String: Any]
        return read?["text"] as? String ?? ""
    }

    @Test("讀含 ANSI 的畫面:pane.read 帶 format ansi(visible、40 行),bridge 不送 EOF,回傳原樣畫面")
    func readsANSIScreen() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: .recorded("pane.read.ansi.suggestion.ndjson"))

        let text = try await HerdrClient(channel: host).readPane(paneID: "w1:pA", format: .ansi)

        #expect(text == Self.screen("suggestion"))
        #expect(text.contains("\u{1B}[2madd subtract to calc.py"))
        let execution = try #require(await host.executions.first)
        #expect(execution.stdinText == #"{"id":"purrdr:pane.read","method":"pane.read","params":{"format":"ansi","lines":40,"pane_id":"w1:pA","source":"visible"}}"# + "\n")
        #expect(execution.closedStdin == false)
    }

    @Test("Claude 回完一輪後輸入列的 dim 文字是建議")
    func detectsSuggestion() {
        #expect(PromptSuggestion.detect(screen: Self.screen("suggestion")) == "add subtract to calc.py")
    }

    @Test("輸入列有使用者打的字(沒有 dim)時沒有建議")
    func typedInputIsNotSuggestion() {
        let screen = Self.screen("typed")
        #expect(screen.contains("❯\u{00A0}hello there"))
        #expect(PromptSuggestion.detect(screen: screen) == nil)
    }

    @Test("輸入列空白(plan mode 的一輪不產生建議)時沒有建議;畫面上已送出的 prompt 不算")
    func emptyInputHasNoSuggestion() {
        #expect(PromptSuggestion.detect(screen: Self.screen("no-suggestion")) == nil)
    }

    @Test("session 剛開時輸入列的 dim 範例 Try \"…\" 不是建議(含引號內 … 截斷的長範例)", arguments: ["session-start", "session-start-short"])
    func sessionStartExampleIsNotSuggestion(name: String) {
        let screen = Self.screen(name)
        #expect(screen.contains("\u{1B}[2mTry \""))
        #expect(PromptSuggestion.detect(screen: screen) == nil)
    }

    /// 錄不到(2.1.326 已修正，CHANGELOG):以錄製的建議畫面為底，把建議文字換成裸標籤。
    @Test("建議是 <signal … /> 這類裸標籤時不算建議", arguments: [#"<signal type="empty" />"#, "<signal/>"])
    func bareTagIsNotSuggestion(tag: String) {
        let screen = Self.screen("suggestion").replacingOccurrences(of: "add subtract to calc.py", with: tag)
        #expect(screen.contains("\u{1B}[2m\(tag)"))
        #expect(PromptSuggestion.detect(screen: screen) == nil)
    }

    @Test("文字中間提到標籤的一般建議照常顯示")
    func suggestionMentioningTagIsKept() {
        let text = "explain what <signal /> means"
        let screen = Self.screen("suggestion").replacingOccurrences(of: "add subtract to calc.py", with: text)
        #expect(PromptSuggestion.detect(screen: screen) == text)
    }
}
