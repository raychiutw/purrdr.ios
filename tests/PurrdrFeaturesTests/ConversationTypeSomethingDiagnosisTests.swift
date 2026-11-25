import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 診斷與新行為:問題卡的「Type something」送不出(單題、多題分頁、間歇)、直接在輸入列打字、Chat about this。
/// 「卡住」= 使用者看得到的狀態:送出鈕停用(`canSend` 為 false)、按了沒反應(沒有按鍵、沒有提示)、打的字不見。
@MainActor
@Suite("Type something 診斷")
struct ConversationTypeSomethingDiagnosisTests {
    typealias Answer = ConversationAnswerTests
    typealias Typed = ConversationTypedAnswerTests

    static func asking(_ screen: String) async throws -> (Answer.Setup, PromptOption) {
        let setup = try Answer.setup()
        await Answer.expectPoll(setup, screen: screen)
        await setup.model.poll()
        let prompt = try #require(setup.model.prompt)
        let typed = try #require(prompt.typedAnswerOption(agentKind: "claude"), "選項:\(prompt.options.map(\.label))")
        return (setup, typed)
    }

    // MARK: 解析

    @Test("Chat about this 是問題卡的選項(單題與多題分頁),Type something. 仍是自訂回答",
          arguments: ["claude-ask-question-chat", "claude-ask-tabs-chat"])
    func chatOptionParsed(screen: String) async throws {
        let (setup, typed) = try await Self.asking(screen)
        let prompt = try #require(setup.model.prompt)
        #expect(typed.label == "Type something." && typed.number == 4)
        #expect(prompt.chatOption?.number == 5, "選項:\(prompt.options.map(\.label))")
    }

    // MARK: 症狀 1(c):Type something

    @Test("單題與多題分頁:Type something 能進入、送出按鍵(4、文字、enter)",
          arguments: ["claude-ask-question", "claude-ask-question-chat", "claude-ask-tabs-chat"])
    func typedAnswerSends(screen: String) async throws {
        let (setup, typed) = try await Self.asking(screen)
        #expect(setup.model.canBeginTypedAnswer(typed))
        setup.model.beginTypedAnswer(typed)
        #expect(setup.model.typedAnswer == typed)
        for _ in 0..<3 { await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted) }
        setup.model.draft = "Teal"
        #expect(setup.model.canSend)
        await setup.model.send()
        #expect(await Typed.inputRequests(setup) == [Answer.keys(["4"]), Typed.text("Teal"), Answer.keys(["enter"])])
    }

    /// 假設:輪詢讀到暫時看不出選單的畫面(重繪中途)時,提示被換成通用鈕,自訂回答被結束、打的字被換成原草稿,
    /// 送出鈕仍亮但按下去什麼都沒發生。預測:打字中輪詢到一張非選單畫面,仍要停在自訂回答、字還在、送得出去。
    @Test("打字中輪詢讀到暫時看不出選單的畫面:自訂回答與文字保留")
    func transientUnparsableScreenKeepsTypedAnswer() async throws {
        let (setup, typed) = try await Self.asking("claude-ask-question")
        setup.model.beginTypedAnswer(typed)
        setup.model.draft = "Teal"

        await Answer.expectPoll(setup, screen: "claude-idle")
        await setup.model.poll()

        #expect(setup.model.typedAnswer == typed, "自訂回答被結束了;draft=\(setup.model.draft)")
        #expect(setup.model.draft == "Teal")
        for _ in 0..<3 { await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted) }
        await setup.model.send()
        #expect(await Typed.inputRequests(setup) == [Answer.keys(["4"]), Typed.text("Teal"), Answer.keys(["enter"])])
    }

    /// 假設:題目在背景被換掉時,打到一半的字被換回原草稿(字不見)。預測:換題後字仍在輸入框、沒有送出任何按鍵。
    @Test("題目被換掉:打到一半的字留在輸入框,不送出任何按鍵")
    func questionChangedKeepsTypedText() async throws {
        let (setup, typed) = try await Self.asking("claude-ask-question")
        setup.model.beginTypedAnswer(typed)
        setup.model.draft = "Teal"

        await Answer.expectPoll(setup, screen: "claude-ask-review")
        await setup.model.poll()

        #expect(setup.model.typedAnswer == nil)
        #expect(setup.model.draft == "Teal", "打的字不見了:\(setup.model.draft)")
        #expect(await Typed.inputRequests(setup).isEmpty)
    }

    // MARK: 症狀 2(a):問題卡開著直接在輸入列送出

    @Test("有 Chat about this:先選它(5),等 Agent 可輸入,再把文字當一般 prompt 送出")
    func directSendChoosesChat() async throws {
        let (setup, _) = try await Self.asking("claude-ask-question-chat")
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted)
        await Answer.expectPoll(setup, status: "idle", screen: "claude-idle")
        await setup.host.bridge.expect(Answer.bridge, reply: Answer.snapshot(status: "idle"))
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.prompted())
        setup.model.draft = "Teal"

        await setup.model.send()

        let requests = await Typed.inputRequests(setup)
        #expect(requests.count == 2, "\(requests)")
        #expect(requests.first == Answer.keys(["5"]))
        #expect(requests.last?.contains(#""method":"agent.prompt""#) == true && requests.last?.contains("Teal") == true)
        #expect(setup.model.notice == nil && setup.model.draft == "")
    }

    @Test("沒有 Chat about this 的問題卡:先送 Esc,再把文字當一般 prompt 送出")
    func directSendEscapesWithoutChat() async throws {
        let (setup, _) = try await Self.asking("claude-ask-question")
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted)
        await Answer.expectPoll(setup, status: "idle", screen: "claude-idle")
        await setup.host.bridge.expect(Answer.bridge, reply: Answer.snapshot(status: "idle"))
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.prompted())
        setup.model.draft = "Teal"

        await setup.model.send()

        let requests = await Typed.inputRequests(setup)
        #expect(requests.first == Answer.keys(["esc"]), "\(requests)")
        #expect(requests.last?.contains(#""method":"agent.prompt""#) == true)
        #expect(setup.model.notice == nil && setup.model.draft == "")
    }

    @Test("權限提示這類不是問題卡的選單:直接打字不會替使用者按 Esc(照舊提示先回答)")
    func directSendDoesNotDismissPermissionPrompt() async throws {
        let setup = try Answer.setup()
        await Answer.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Answer.bridge, reply: Answer.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.error("agent_blocked", "agent is blocked"))
        await setup.host.bridge.expect(Answer.bridge, reply: PaneScreens.read("claude-bash"))
        setup.model.draft = "Teal"

        await setup.model.send()

        let requests = await Typed.inputRequests(setup)
        #expect(!requests.contains(Answer.keys(["esc"])) && !requests.contains(Answer.keys(["5"])))
        #expect(setup.model.draft == "Teal")
    }

    // MARK: 症狀 3(b):Chat about this

    @Test("點 Chat about this:送 5,卡片收起")
    func chatAboutThisAnswer() async throws {
        let (setup, _) = try await Self.asking("claude-ask-question-chat")
        let chat = try #require(setup.model.prompt?.chatOption)
        #expect(setup.model.canAnswer(.option(chat)))
        await setup.host.bridge.expect(Answer.bridge, reply: PromptReplies.keysAccepted)

        await setup.model.answer(.option(chat))
        #expect(await Typed.inputRequests(setup) == [Answer.keys(["5"])])

        await Answer.expectPoll(setup, status: "idle", screen: "claude-idle")
        await setup.model.poll()
        #expect(setup.model.prompt == nil)
        #expect(setup.model.answerInFlight == nil)
    }
}
