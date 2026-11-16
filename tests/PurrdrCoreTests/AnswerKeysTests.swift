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

    @Test("Claude、Grok、Antigravity 的編號選項只送數字(多一個 Enter 會回答下一題)", arguments: ["claude", "grok", "agy", "antigravity"])
    func digitOnlyAgents(kind: String) {
        #expect(AnswerKeys.keys(for: .option(Self.option(2)), agentKind: kind) == ["2"])
    }

    @Test("Codex、Pi、OMP 與不認得的 agent:數字再 Enter(Codex 的數字只移動游標)", arguments: ["codex", "pi", "omp", "opencode", ""])
    func digitThenEnterAgents(kind: String) {
        #expect(AnswerKeys.keys(for: .option(Self.option(3)), agentKind: kind) == ["3", "enter"])
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
}
