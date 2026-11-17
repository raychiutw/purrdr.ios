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

    // MARK: - code review(#124)

    /// 錄製建議畫面的輸入列(含行尾)。
    static let recordedInputLine = "❯\u{00A0}\u{1B}[0m\u{1B}[2madd subtract to calc.py\u{1B}[0m\r\n"

    /// 錄不到換行的長建議：以錄製的建議畫面為底，把輸入列換成兩行——第一行 `❯`+NBSP 加 dim 文字，
    /// 第二行縮排兩格接著 dim 文字(與 Claude Code 多行輸入的縮排相同),兩行都在輸入框上下分隔線之間。
    @Test("換行的長建議：接續輸入框分隔線之間的 dim 後續行，不給半句")
    func wrappedSuggestionIsJoined() {
        let wrapped = "❯\u{00A0}\u{1B}[0m\u{1B}[2madd subtract and multiply to calc.py, then write unit tests\u{1B}[0m\r\n"
            + "  \u{1B}[0m\u{1B}[2mfor both functions in test_calc.py\u{1B}[0m\r\n"
        let screen = Self.screen("suggestion").replacingOccurrences(of: Self.recordedInputLine, with: wrapped)
        #expect(screen.contains("for both functions"))
        #expect(
            PromptSuggestion.detect(screen: screen)
                == "add subtract and multiply to calc.py, then write unit tests for both functions in test_calc.py"
        )
    }

    /// 以錄製的建議畫面為底，在輸入列下面加一行沒有 dim 的字(使用者打的多行輸入):整段不是建議。
    @Test("輸入框裡的後續行有非 dim 的字：不是建議")
    func continuationWithTypedTextIsNotSuggestion() {
        let screen = Self.screen("suggestion").replacingOccurrences(
            of: Self.recordedInputLine, with: Self.recordedInputLine + "  typed by hand\r\n"
        )
        #expect(PromptSuggestion.detect(screen: screen) == nil)
    }

    /// 以錄製的建議畫面為底，把輸入列以下全部刪掉(像畫面被截斷、沒有輸入框下緣分隔線):無法確定建議完整，不顯示。
    @Test("找不到輸入框下緣分隔線：不顯示(寧可沒有也不給半句)")
    func missingBottomSeparatorHasNoSuggestion() throws {
        let screen = Self.screen("suggestion")
        let range = try #require(screen.range(of: Self.recordedInputLine))
        #expect(PromptSuggestion.detect(screen: String(screen[..<range.upperBound])) == nil)
    }

    /// 以錄製的建議畫面為底，在 `❯` 前面加 SGR 與游標序列。
    @Test(
        "輸入列的 ❯ 前面有 SGR／游標序列仍認得",
        arguments: ["\u{1B}[0m", "\u{1B}[0m\u{1B}[38;2;153;153;153m", "\u{1B}[?25l\u{1B}[0m"]
    )
    func leadingEscapesBeforePrompt(prefix: String) {
        let screen = Self.screen("suggestion").replacingOccurrences(of: Self.recordedInputLine, with: prefix + Self.recordedInputLine)
        #expect(PromptSuggestion.detect(screen: screen) == "add subtract to calc.py")
    }

    /// 以錄製的建議畫面為底，在 dim 之後插入帶冒號子參數的 SGR(曲線底線、真彩色前景、底線顏色);它們不是重設，dim 維持。
    @Test(
        "冒號子參數的 SGR(4:3、38:2::r:g:b)不會關掉 dim",
        arguments: ["\u{1B}[4:3m", "\u{1B}[38:2::153:153:153m", "\u{1B}[58:5:1m"]
    )
    func colonSubparametersKeepDim(sgr: String) {
        let screen = Self.screen("suggestion").replacingOccurrences(of: "\u{1B}[2madd subtract", with: "\u{1B}[2m\(sgr)add subtract")
        #expect(PromptSuggestion.detect(screen: screen) == "add subtract to calc.py")
    }

    @Test("去掉 ANSI:OSC 8 超連結、CSI 中間位元組與 <=> 私有參數、冒號子參數、單字元跳脫")
    func stripsANSI() {
        let text = "\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{1B}\\ a\u{1B}[2 qb\u{1B}[>4;1mc\u{1B}[=5ud\u{1B}[38:2::1:2:3me\u{1B}7f\r\n"
        #expect(ANSIText.strip(text) == "link abcdef\r\n")
    }
}
