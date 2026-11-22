import PurrdrCore
import PurrdrTestSupport
import Testing

/// 回答「需要你」時送出的按鍵(行為規格 §5.5、R-Q03、R-Q04、R-Q07、R-Q08)。
///
/// 多一個 Enter 會回答下一題或在多選中多勾一列;Codex 的數字只移動游標，少了 Enter 就沒回答。
@Suite("回答的按鍵")
struct AnswerKeysTests {
    static func option(_ number: Int?, keys: [String]? = nil, checked: Bool? = nil) -> PromptOption {
        PromptOption(number: number, label: "Option", checked: checked, keys: keys)
    }

    @Test("Claude、Antigravity 的編號選項只送數字(多一個 Enter 會回答下一題)", arguments: ["claude", "agy", "antigravity", "antigravity-cli"])
    func digitOnlyAgents(kind: String) {
        #expect(AnswerKeys.keys(for: .option(Self.option(2)), agentKind: kind) == ["2"])
    }

    @Test("Codex:數字再 Enter(數字只移動游標)", arguments: ["codex"])
    func digitThenEnterAgents(kind: String) {
        #expect(AnswerKeys.keys(for: .option(Self.option(3)), agentKind: kind) == ["3", "enter"])
    }

    /// #440:回答按鍵沒驗證過就不送(送錯鍵可能誤放行危險操作);畫面改讓使用者打字或到終端機操作。
    @Test("按鍵沒驗證過的 agent(Grok、Pi、OMP)與只有顯示資訊的 agent 不送任何回答按鍵", arguments: ["grok", "grok-build", "pi", "omp", "opencode", "copilot", "somebody-new", ""])
    func unverifiedAgentsSendNothing(kind: String) {
        let option = Self.option(2)
        #expect(AnswerKeys.keys(for: .option(option), agentKind: kind) == nil)
        #expect(AnswerKeys.keys(for: .option(Self.option(nil, keys: ["down", "enter"])), agentKind: kind) == nil)
        #expect(AnswerKeys.keys(for: .continueMultiSelect, agentKind: kind) == nil)
        #expect(AnswerKeys.keys(for: .closePicker, agentKind: kind) == nil)
        #expect(AnswerKeys.keys(for: .generic(.confirm), agentKind: kind) == nil)
        #expect(AnswerKeys.keys(for: .generic(.escape), agentKind: kind) == nil)
        #expect(AnswerKeys.inputs(for: .option(option), agentKind: kind) == nil)
    }

    @Test("編號 1–9 以外不能從手機回答(「10」會先選 1,再送出雜訊)", arguments: [10, 11, 0])
    func outOfRangeNumbersAreDisabled(number: Int) {
        #expect(AnswerKeys.keys(for: .option(Self.option(number)), agentKind: "claude") == nil)
        #expect(AnswerKeys.keys(for: .option(Self.option(number)), agentKind: "codex") == nil)
    }

    @Test("編號 1 與 9 是可回答的邊界")
    func boundaryNumbersAreAnswerable() {
        #expect(AnswerKeys.keys(for: .option(Self.option(1)), agentKind: "claude") == ["1"])
        #expect(AnswerKeys.keys(for: .option(Self.option(9)), agentKind: "claude") == ["9"])
    }

    @Test("多選列只送數字(切換勾選),即使是要 Enter 的 agent")
    func checkboxRowsSendDigitOnly() {
        #expect(AnswerKeys.keys(for: .option(Self.option(2, checked: false)), agentKind: "codex") == ["2"])
    }

    @Test("選項帶自己的按鍵(資料夾信任)時照送，不加數字")
    func ownKeysWin() {
        let trust = Self.option(nil, keys: ["down", "enter"])
        #expect(AnswerKeys.keys(for: .option(trust), agentKind: "claude") == ["down", "enter"])
        #expect(AnswerKeys.keys(for: .option(trust), agentKind: "codex") == ["down", "enter"])
    }

    @Test("沒有編號也沒有自己的按鍵的選項不能回答")
    func unnumberedWithoutKeysIsDisabled() {
        #expect(AnswerKeys.keys(for: .option(Self.option(nil)), agentKind: "claude") == nil)
    }

    @Test("多選的「繼續」送 right;關閉選擇器送 esc;通用鈕")
    func otherAnswers() {
        #expect(AnswerKeys.keys(for: .continueMultiSelect, agentKind: "claude") == ["right"])
        #expect(AnswerKeys.keys(for: .closePicker, agentKind: "codex") == ["esc"])
        #expect(AnswerKeys.keys(for: .generic(.confirm), agentKind: "claude") == ["enter"])
        #expect(AnswerKeys.keys(for: .generic(.one), agentKind: "claude") == ["1", "enter"])
        #expect(AnswerKeys.keys(for: .generic(.two), agentKind: "claude") == ["2", "enter"])
        #expect(AnswerKeys.keys(for: .generic(.escape), agentKind: "claude") == ["esc"])
    }

    // MARK: - 「Type something.」自訂回答(#120)

    static let askQuestion = BlockedPromptParser.parse(screen: PaneScreens.text("claude-ask-question"), agentKind: "claude")

    @Test("Claude 選單最後一個編號選項「Type something.」是自訂回答")
    func typeSomethingIsRecognized() throws {
        let prompt = try #require(Self.askQuestion)
        #expect(prompt.typedAnswerOption(agentKind: "claude") == prompt.options[3])
    }

    @Test("不是 Claude、多選的「Type something」、不在最後一列的同名選項都不算自訂回答")
    func typeSomethingOnlyForClaudeLastOption() throws {
        let prompt = try #require(Self.askQuestion)
        #expect(prompt.typedAnswerOption(agentKind: "codex") == nil)
        let multi = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("claude-ask-multiselect"), agentKind: "claude"))
        #expect(multi.typedAnswerOption(agentKind: "claude") == nil)
        var moved = prompt
        moved.options.swapAt(2, 3)
        #expect(moved.typedAnswerOption(agentKind: "claude") == nil)
    }

    @Test("「Type something.」不再只送數字(數字只會把那一列變成文字輸入)")
    func typeSomethingOptionAloneSendsNothing() throws {
        let option = try #require(Self.askQuestion?.options[3])
        #expect(AnswerKeys.keys(for: .option(option), agentKind: "claude") == nil)
    }

    @Test("自訂回答：數字 → 文字(send_text)→ enter")
    func typedAnswerInputs() throws {
        let option = try #require(Self.askQuestion?.options[3])
        #expect(AnswerKeys.inputs(for: .typed(option, text: "綠色 green"), agentKind: "claude") == [
            .keys(["4"]), .text("綠色 green"), .keys(["enter"]),
        ])
    }

    @Test("自訂回答：換行換成空格、去掉頭尾空白(行內輸入的換行會提早送出，剩下的字落到下一題)")
    func typedAnswerFlattensNewlines() throws {
        let option = try #require(Self.askQuestion?.options[3])
        #expect(AnswerKeys.inputs(for: .typed(option, text: " teal\nwith  stripes\r\n"), agentKind: "claude") == [
            .keys(["4"]), .text("teal with  stripes"), .keys(["enter"]),
        ])
    }

    @Test("自訂回答：空白文字不送")
    func blankTypedAnswerSendsNothing() throws {
        let option = try #require(Self.askQuestion?.options[3])
        #expect(AnswerKeys.inputs(for: .typed(option, text: "  \n"), agentKind: "claude") == nil)
    }

    @Test("一般回答的輸入就是它的按鍵")
    func plainAnswerInputsAreKeys() {
        #expect(AnswerKeys.inputs(for: .option(Self.option(2)), agentKind: "claude") == [.keys(["2"])])
        #expect(AnswerKeys.inputs(for: .option(Self.option(10)), agentKind: "claude") == nil)
    }
}
