import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 「需要你」浮動卡的選項狀態(#424):送出中其他選項停用、列高不變所需的狀態，以及失敗後恢復。
@MainActor
@Suite("需要你選項狀態")
struct NeedsYouOptionStateTests {
    typealias Answers = ConversationAnswerTests

    private static func promptShown() async throws -> (ConversationAnswerTests.Setup, [PromptOption]) {
        let setup = try Answers.setup()
        await Answers.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        return (setup, try #require(setup.model.prompt?.options))
    }

    @Test("沒有回答在途：每個選項都可選")
    func idleOptionsAreAvailable() async throws {
        let (setup, options) = try await Self.promptShown()

        #expect(options.map(setup.model.optionState(for:)) == Array(repeating: .available, count: options.count))
    }

    @Test("送出中：被按的選項是 sending,其他選項是 disabled")
    func sendingMarksPressedAndDisablesOthers() async throws {
        let (setup, options) = try await Self.promptShown()
        await setup.host.bridge.expect(Answers.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(options[0]))

        #expect(setup.model.answerInFlight == .option(options[0]))
        #expect(setup.model.optionState(for: options[0]) == .sending)
        #expect(setup.model.optionState(for: options[1]) == .disabled)
        #expect(setup.model.optionState(for: options[2]) == .disabled)
    }

    @Test("送出失敗：選項恢復可選，並留下送出失敗的提示")
    func failureRestoresOptions() async throws {
        let (setup, options) = try await Self.promptShown()
        await setup.host.bridge.expect(Answers.bridge, reply: PromptReplies.error("pane_not_found", "pane w1:p6 not found"))
        await setup.model.answer(.option(options[0]))

        #expect(setup.model.answerNotice == .sendFailed)
        #expect(options.map(setup.model.optionState(for:)) == Array(repeating: .available, count: options.count))
    }
}
