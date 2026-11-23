import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 診斷用:回答「需要你」之後卡片退回通用鈕(「Agent 正在等你。」＋確認／選 1／選 2／取消)的情形。
/// 紅燈 = 目前行為(答完、herdr 狀態還是 blocked 但畫面已不是選單時，通用鈕冒出來)。
@MainActor
@Suite("回答需要你後的通用鈕")
struct ConversationNeedsYouFallbackTests {
    typealias A = ConversationAnswerTests

    /// 答了一題;之後 herdr 的狀態(過時的快照或事件)仍是 blocked,畫面卻已是別的(Agent 回到輸入列)。
    /// 期望:不能把「已答完」的卡片換成通用鈕——通用鈕的 Return／1／2／Esc 會真的打進 Agent。
    @Test("答完後狀態還是 blocked、畫面不是選單：不顯示通用鈕")
    func staleBlockedAfterAnswerDoesNotShowGenericButtons() async throws {
        let setup = try A.setup()
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await setup.host.bridge.expect(A.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))

        await A.expectPoll(setup, status: "blocked", screen: "claude-idle")
        await setup.model.poll()

        #expect(setup.model.prompt?.kind != .unrecognized, "答完的題目被通用鈕取代:\(String(describing: setup.model.prompt?.kind))")
    }

    /// 使用者的實際情形:送出還在進行中(`pane.send_keys` 還沒回,`answerSent` 仍是 nil),
    /// 按鍵其實已到 Agent、畫面重繪成不是選單的樣子,此時輪詢(blocked + 讀畫面)把卡片換成通用鈕;
    /// 回應回來後回答才算送出。期望:送出中卡片維持原本的題目與選項。
    @Test("送出進行中、輪詢讀到非選單畫面(狀態仍 blocked):卡片維持原題目，不切成通用鈕")
    func redrawDuringSendKeepsParsedPrompt() async throws {
        let setup = try A.setup()
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        let original = try #require(setup.model.prompt)
        await setup.host.bridge.expect(A.bridge, reply: PromptReplies.silent)  // send_keys 還沒回應
        let option = try #require(original.options.first)

        let sending = Task { await setup.model.answer(.option(option)) }
        try await waitUntil { await A.keyRequests(setup).count == 1 }
        #expect(setup.model.answerInFlight == .option(option))

        await A.expectPoll(setup, status: "blocked", screen: "claude-idle")
        await setup.model.poll()

        #expect(setup.model.prompt?.kind == original.kind, "送出中卡片變成:\(String(describing: setup.model.prompt?.kind))")
        #expect(setup.model.prompt?.question == original.question)
        sending.cancel()
    }

    /// 自動送出那半:同一個回答的按鍵只能送一次,不論之後輪詢、重新連線或同一題畫面重現。
    @Test("答完後離線、重新連線、同一題畫面重現：回答的按鍵只送一次")
    func answerKeysSentOnceAcrossReconnect() async throws {
        let setup = try A.setup()
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await setup.host.bridge.expect(A.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))

        await setup.model.poll()  // 沒有預期的回應 = 讀不到主機(離線)
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()

        #expect(await A.keyRequests(setup) == [A.keys(["1"])])
    }

    /// 答完後 herdr 的 blocked 還沒更新、畫面又讀不到(離線):期限內不能因為「沒有提示」就冒出通用鈕。
    @Test("答完後狀態還是 blocked、之後讀不到畫面(離線)：期限內不顯示通用鈕")
    func staleBlockedThenOfflineDoesNotShowGenericButtons() async throws {
        let setup = try A.setup()
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await setup.host.bridge.expect(A.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))
        await A.expectPoll(setup, status: "blocked", screen: "claude-idle")
        await setup.model.poll()

        await A.expectPoll(setup, status: "blocked", screen: nil)  // 畫面讀不到
        await setup.model.poll()

        #expect(setup.model.prompt?.kind != .unrecognized, "離線時答完的題目冒出通用鈕:\(String(describing: setup.model.prompt?.kind))")
    }

    /// 守門:送出中畫面上真的出現下一題(不同的選單)時要換成新題目,不能卡在舊卡。
    @Test("送出進行中、畫面出現新題目：換成新題目")
    func newQuestionDuringSendReplacesCard() async throws {
        let setup = try A.setup()
        await A.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        let original = try #require(setup.model.prompt)
        await setup.host.bridge.expect(A.bridge, reply: PromptReplies.silent)
        let option = try #require(original.options.first)
        let sending = Task { await setup.model.answer(.option(option)) }
        try await waitUntil { await A.keyRequests(setup).count == 1 }

        await A.expectPoll(setup, status: "blocked", screen: "claude-ask-review")
        await setup.model.poll()

        #expect(setup.model.prompt?.question != original.question)
        #expect(setup.model.prompt?.kind != .unrecognized)
        sending.cancel()
    }

    /// 守門:沒在回答時,真的讀不懂的提示(畫面讀得到但不是選單、或讀不到畫面)仍給通用鈕。
    @Test("沒在回答時的未知提示仍顯示通用鈕(讀得到畫面與讀不到畫面)")
    func unknownPromptWithoutAnswerStillShowsGenericButtons() async throws {
        let readable = try A.setup()
        await A.expectPoll(readable, screen: "claude-idle")
        await readable.model.poll()
        #expect(readable.model.prompt?.kind == .unrecognized)

        let unreadable = try A.setup()
        await A.expectPoll(unreadable, status: "blocked", screen: nil)
        await unreadable.model.poll()
        #expect(unreadable.model.prompt?.kind == .unrecognized)
    }
}
