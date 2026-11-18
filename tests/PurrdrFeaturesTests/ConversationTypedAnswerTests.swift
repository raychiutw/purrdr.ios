import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Claude 問題卡的「Type something.」(#120):點了以後用底部訊息框打自訂答案，送出時對 pane 送
/// 數字 → `pane.send_text` 文字 → `enter`,不走 `agent.prompt`。
/// herdr 走假主機;`pane.send_keys`／`pane.send_text` 的回應不錄(`PromptReplies.keysAccepted`)。
@MainActor
@Suite("自訂回答(Type something)")
struct ConversationTypedAnswerTests {
    typealias Answer = ConversationAnswerTests

    /// 送給 pane 的輸入與 prompt 請求(依序)。
    static func inputRequests(_ setup: Answer.Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter {
            $0.contains(#""method":"pane.send_keys""#) || $0.contains(#""method":"pane.send_text""#)
                || $0.contains(#""method":"agent.prompt""#)
        }
    }

    static func text(_ text: String) -> String {
        #"{"id":"purrdr:pane.send_text","method":"pane.send_text","params":{"pane_id":"w1:p6","text":"\#(text)"}}"# + "\n"
    }

    /// 問題卡開著(Type something. 是 4)的模型。
    static func setupAsking() async throws -> (Answer.Setup, PromptOption) {
        let setup = try Answer.setup()
        await Answer.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        let option = try #require(setup.model.prompt?.options.last)
        return (setup, option)
    }

    @Test("點「Type something.」不送任何按鍵，進入自訂回答;輸入框先清空、原本的草稿留著")
    func beginningSendsNothing() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"

        #expect(setup.model.canAnswer(.option(option)) == false)
        setup.model.beginTypedAnswer(option)

        #expect(setup.model.typedAnswer == option)
        #expect(setup.model.draft == "")
        #expect(setup.model.canSend == false)
        #expect(await Self.inputRequests(setup).isEmpty)
    }

    @Test("送出：數字 → send_text 文字 → enter,不送 agent.prompt;原本的草稿放回")
    func sendingTypesDigitTextEnter() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"
        setup.model.beginTypedAnswer(option)
        for _ in 0..<3 { await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted) }
        setup.model.draft = "綠色 green"
        #expect(setup.model.canSend)

        await setup.model.send()

        #expect(await Self.inputRequests(setup) == [Answer.keys(["4"]), Self.text("綠色 green"), Answer.keys(["enter"])])
        #expect(setup.model.answerInFlight == .typed(option, text: "綠色 green"))
        #expect(setup.model.typedAnswer == nil)
        #expect(setup.model.draft == "earlier draft")
    }

    @Test("送達：換成下一題 → 記下打的文字")
    func deliveredShowsTypedText() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.beginTypedAnswer(option)
        for _ in 0..<3 { await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted) }
        setup.model.draft = "Teal"
        await setup.model.send()

        await Answer.expectPoll(setup, screen: "claude-ask-review")
        await setup.model.poll()

        #expect(setup.model.lastAnswer == AnsweredPrompt(question: "Which color should the chart use?", choice: "Teal"))
        #expect(setup.model.answerInFlight == nil)
    }

    @Test("取消：回到一般輸入，草稿放回，什麼都不送")
    func cancelRestoresDraft() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"
        setup.model.beginTypedAnswer(option)
        setup.model.draft = "half"

        setup.model.cancelTypedAnswer()

        #expect(setup.model.typedAnswer == nil)
        #expect(setup.model.draft == "earlier draft")
        #expect(await Self.inputRequests(setup).isEmpty)
    }

    @Test("打過字之後清空訊息框：離開自訂回答，草稿放回，什麼都不送(#127)")
    func clearingAfterTypingEndsTypedAnswer() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"
        setup.model.beginTypedAnswer(option)
        setup.model.draft = "hal"

        setup.model.draft = ""

        #expect(setup.model.typedAnswer == nil)
        #expect(setup.model.draft == "earlier draft")
        #expect(await Self.inputRequests(setup).isEmpty)
    }

    @Test("剛進入自訂回答、還沒打字時訊息框本來就空：仍停在自訂回答(#127)")
    func emptyBeforeTypingStaysInTypedAnswer() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"
        setup.model.beginTypedAnswer(option)

        setup.model.draft = ""

        #expect(setup.model.typedAnswer == option)
        #expect(setup.model.draft == "")
    }

    @Test("送不出去後回到自訂回答，再清空訊息框：離開自訂回答(#127)")
    func clearingAfterSendFailureEndsTypedAnswer() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"
        setup.model.beginTypedAnswer(option)
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.error("pane_not_found", "pane w1:p6 not found"))
        setup.model.draft = "Teal"
        await setup.model.send()
        #expect(setup.model.typedAnswer == option)

        setup.model.draft = ""

        #expect(setup.model.typedAnswer == nil)
        #expect(setup.model.draft == "earlier draft")
    }

    @Test("提示不見了(在終端機回答掉):離開自訂回答，草稿放回")
    func promptGoneEndsTypedAnswer() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.draft = "earlier draft"
        setup.model.beginTypedAnswer(option)

        await Answer.expectPoll(setup, status: "working", screen: nil)
        await setup.model.poll()

        #expect(setup.model.typedAnswer == nil)
        #expect(setup.model.draft == "earlier draft")
    }

    @Test("送不出去：顯示錯誤，回到自訂回答並保留打的字")
    func sendFailureKeepsTypedText() async throws {
        let (setup, option) = try await Self.setupAsking()
        setup.model.beginTypedAnswer(option)
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.error("pane_not_found", "pane w1:p6 not found"))
        setup.model.draft = "Teal"

        await setup.model.send()

        #expect(setup.model.answerNotice == .sendFailed)
        #expect(setup.model.typedAnswer == option)
        #expect(setup.model.draft == "Teal")
    }

    @Test("不是 Claude 的最後一列「Type something.」:不能進入自訂回答")
    func onlyForClaudeTypeSomething() async throws {
        let (setup, _) = try await Self.setupAsking()
        let first = try #require(setup.model.prompt?.options.first)

        setup.model.beginTypedAnswer(first)

        #expect(setup.model.typedAnswer == nil)
    }
}
