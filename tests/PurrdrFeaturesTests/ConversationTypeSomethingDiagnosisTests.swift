import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 診斷:「Type something」輸入送不出、直接打字沒效果、Chat about this。
@MainActor
@Suite("Type something 診斷")
struct ConversationTypeSomethingDiagnosisTests {
    typealias Answer = ConversationAnswerTests
    typealias Typed = ConversationTypedAnswerTests

    /// 症狀 1:選項列最後還有「Chat about this」(分隔線之後)時，「Type something.」仍能進入自訂回答並送出。
    @Test("症狀1:Type something 後面有 Chat about this 時仍可打字回答")
    func typeSomethingWithChatAboutThis() async throws {
        let setup = try Answer.setup()
        await Answer.expectPoll(setup, screen: "claude-ask-question-chat")
        await setup.model.poll()
        let prompt = try #require(setup.model.prompt)
        let labels = prompt.options.map(\.label)
        let typed = try #require(prompt.options.first { $0.label == "Type something." }, "選項:\(labels)")
        #expect(setup.model.isTypedAnswerOption(typed), "選項:\(labels)")
        setup.model.beginTypedAnswer(typed)
        #expect(setup.model.typedAnswer == typed)
        for _ in 0..<3 { await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted) }
        setup.model.draft = "Teal"
        await setup.model.send()
        #expect(await Typed.inputRequests(setup) == [Answer.keys(["4"]), Typed.text("Teal"), Answer.keys(["enter"])])
    }

    /// 症狀 2:問題卡開著、不點選項直接在輸入列打字送出。
    @Test("症狀2:問題卡開著直接送出")
    func directSendWhileAsking() async throws {
        let setup = try Answer.setup()
        await Answer.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.error("agent_blocked", "agent is blocked"))
        setup.model.draft = "Teal"
        await setup.model.send()
        let requests = await Typed.inputRequests(setup)
        print("[DEBUG] requests=\(requests) notice=\(String(describing: setup.model.notice)) draft=\(setup.model.draft) typed=\(String(describing: setup.model.typedAnswer))")
        #expect(setup.model.notice == nil && setup.model.draft == "", "notice=\(String(describing: setup.model.notice)) draft=\(setup.model.draft)")
    }
}
