import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 回答「需要你」的狀態機(#560):直接打 interface,以注入的時間與畫面字串驗證規則,不搭主機替身。
@Suite("回答需要你的狀態機")
struct AnswerFlowTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let permission = PaneScreens.text("claude-bash")
    static let question = PaneScreens.text("claude-ask-question")
    static let idle = PaneScreens.text("claude-idle")
    static let dialect = AgentCatalog.profile(forHerdrName: "claude").screen

    static func observation(blocked: Bool = true, working: Bool = false, session: Bool = true, at offset: TimeInterval = 0, draft: String = "") -> AnswerFlow.Observation {
        .init(isBlocked: blocked, isWorking: working, hasSession: session, now: t0.addingTimeInterval(offset), draft: draft)
    }

    /// 一輪:`begin` 決定要讀畫面就以 `screen` 結算。
    @discardableResult
    static func poll(_ flow: inout AnswerFlow, screen: String?, blocked: Bool = true, working: Bool = false, session: Bool = true,
                     at offset: TimeInterval = 0, draft: String = "") -> AnswerFlow.Outcome {
        let o = observation(blocked: blocked, working: working, session: session, at: offset, draft: draft)
        switch flow.begin(o) {
        case .settled(let outcome): return outcome
        case .readScreen: return flow.observe(screen: screen, dialect: dialect, o)
        }
    }

    /// 已讀到權限選單、選了第一個並送達的狀態。
    static func answered(sentAt offset: TimeInterval = 0) -> (AnswerFlow, PromptAnswer) {
        var flow = AnswerFlow(agentKind: "claude")
        poll(&flow, screen: permission)
        let answer = PromptAnswer.option(flow.prompt!.options[0])
        _ = flow.begin(answer: answer, isReadOnly: false)
        _ = flow.finish(answer, result: .sent(lastEntryID: "e1", at: t0.addingTimeInterval(offset)))
        return (flow, answer)
    }

    // MARK: 提示出現與消失

    @Test("blocked 且畫面是選單:卡片出現、標記 Agent 在等")
    func menuAppears() {
        var flow = AnswerFlow(agentKind: "claude")
        let outcome = Self.poll(&flow, screen: Self.permission)
        #expect(flow.prompt?.kind == .menu)
        #expect(outcome.agentBlocked)
        #expect(!outcome.promptGone)
    }

    @Test("blocked 但畫面不是選單:給通用鈕")
    func unrecognizedWhenBlocked() {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.idle)
        #expect(flow.prompt?.kind == .unrecognized)
    }

    @Test("閒置、有 session、沒要求探測:不讀畫面,結算為沒有提示")
    func idleDoesNotRead() {
        var flow = AnswerFlow(agentKind: "claude")
        let step = flow.begin(Self.observation(blocked: false))
        #expect(step == .settled(AnswerFlow.Outcome(agentBlocked: false, haptic: nil, promptGone: true, draft: nil)))
    }

    @Test("閒置但沒有 session 或被要求探測:要讀畫面;工作中不讀")
    func probeRules() {
        var flow = AnswerFlow(agentKind: "claude")
        #expect(flow.begin(Self.observation(blocked: false, session: false)) == .readScreen)
        flow.requestProbe()
        #expect(flow.begin(Self.observation(blocked: false)) == .readScreen)
        // 探測旗標用過就清掉
        #expect(flow.begin(Self.observation(blocked: false)) != .readScreen)
        flow.requestProbe()
        #expect(flow.begin(Self.observation(blocked: false, working: true, session: false)) != .readScreen)
    }

    @Test("閒置時只認資料夾信任,不把對話中的編號清單當提示")
    func idleOnlyTrust() {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission, blocked: false, session: false)
        #expect(flow.prompt == nil)
    }

    @Test("讀不到畫面:不把它當新提示的依據之一以外的任何東西——已有提示就維持,沒有且 blocked 才給通用鈕")
    func unreadableScreen() {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission)
        let before = flow.prompt
        let outcome = Self.poll(&flow, screen: nil)
        #expect(flow.prompt == before)
        #expect(outcome.agentBlocked)

        var fresh = AnswerFlow(agentKind: "claude")
        Self.poll(&fresh, screen: nil)
        #expect(fresh.prompt?.kind == .unrecognized)
    }

    // MARK: 回答

    @Test("回答:鎖住所有選項、送出對應的輸入;選項狀態是送出中與停用")
    func answerLocksOptions() throws {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission)
        let options = try #require(flow.prompt?.options)
        let begun = flow.begin(answer: .option(options[0]), isReadOnly: false)
        let inputs = try #require(begun)
        #expect(!inputs.isEmpty)
        #expect(flow.inFlight == .option(options[0]))
        #expect(flow.optionState(for: options[0], isReadOnly: false) == .sending)
        #expect(flow.optionState(for: options[1], isReadOnly: false) == .disabled)
        // 第二次點擊不再送
        #expect(flow.begin(answer: .option(options[1]), isReadOnly: false) == nil)
    }

    @Test("唯讀裝置不能回答")
    func readOnlyCannotAnswer() throws {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission)
        let option = try #require(flow.prompt?.options.first)
        #expect(!flow.canAnswer(.option(option), isReadOnly: true))
        #expect(flow.begin(answer: .option(option), isReadOnly: true) == nil)
        #expect(flow.optionState(for: option, isReadOnly: true) == .disabled)
    }

    @Test("送出結果:送達排兩次後續輪詢;paneChanged 解鎖、提示、要重讀;唯讀與失敗各自處理")
    func sendResults() throws {
        func fresh() ->  (AnswerFlow, PromptAnswer) {
            var flow = AnswerFlow(agentKind: "claude")
            Self.poll(&flow, screen: Self.permission)
            let answer = PromptAnswer.option(flow.prompt!.options[0])
            _ = flow.begin(answer: answer, isReadOnly: false)
            return (flow, answer)
        }
        var (flow, answer) = fresh()
        let sent = flow.finish(answer, result: .sent(lastEntryID: nil, at: Self.t0))
        #expect(sent.followUpPolls == [.milliseconds(400), .milliseconds(800)])
        #expect(flow.inFlight == answer)

        (flow, answer) = fresh()
        let changed = flow.finish(answer, result: .paneChanged)
        #expect(changed == AnswerFlow.Follow(haptic: .error, marksReadOnly: false, rereadsScreen: true, followUpPolls: []))
        #expect(flow.inFlight == nil)
        #expect(flow.notice == .questionChanged)

        (flow, answer) = fresh()
        let readOnly = flow.finish(answer, result: .readOnlyDevice)
        #expect(readOnly.marksReadOnly)
        #expect(flow.notice == nil)
        #expect(flow.inFlight == nil)

        (flow, answer) = fresh()
        let failed = flow.finish(answer, result: .failed)
        #expect(failed.haptic == .error)
        #expect(flow.notice == .sendFailed)
        #expect(flow.inFlight == nil)
    }

    @Test("paneChanged 之後下一輪一定讀畫面(換上目前的題目),即使 Agent 閒置")
    func paneChangedForcesProbe() throws {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission)
        let first = try #require(flow.prompt?.options.first)
        let answer = PromptAnswer.option(first)
        _ = flow.begin(answer: answer, isReadOnly: false)
        _ = flow.finish(answer, result: .paneChanged)
        #expect(flow.begin(Self.observation(blocked: false, working: false)) == .readScreen)
    }

    @Test("送出途中提示已被結算:晚到的結果不處理")
    func lateResultIgnored() throws {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission)
        let first = try #require(flow.prompt?.options.first)
        let answer = PromptAnswer.option(first)
        _ = flow.begin(answer: answer, isReadOnly: false)
        let follow = flow.finish(.generic(.confirm), result: .failed)
        #expect(follow == AnswerFlow.Follow())
        #expect(flow.inFlight == answer)
    }

    // MARK: 已送達與已回答卡片

    @Test("送達後提示不見:解鎖、留下已回答卡片、播成功觸覺")
    func deliveredWhenPromptGone() throws {
        var (flow, answer) = Self.answered()
        let outcome = Self.poll(&flow, screen: Self.idle, blocked: false, at: 1)
        #expect(outcome.haptic == .success)
        #expect(flow.inFlight == nil)
        let label: String
        if case .option(let option) = answer { label = option.label } else { label = "" }
        #expect(flow.lastAnswer?.choice == label)
        #expect(outcome.promptGone)
    }

    @Test("送達後換成別的題目:視為被取代,新題目不繼承鎖")
    func replacedByNextQuestion() {
        var (flow, _) = Self.answered()
        Self.poll(&flow, screen: Self.question, at: 1)
        #expect(flow.inFlight == nil)
        #expect(flow.lastAnswer != nil)
        #expect(flow.prompt?.options.count == 4)
    }

    @Test("多選的勾選只是切換,不留已回答卡片")
    func checkboxLeavesNoCard() throws {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: PaneScreens.text("claude-ask-multiselect"))
        let option = try #require(flow.prompt?.options.first { $0.checked != nil })
        let answer = PromptAnswer.option(option)
        _ = flow.begin(answer: answer, isReadOnly: false)
        _ = flow.finish(answer, result: .sent(lastEntryID: nil, at: Self.t0))
        Self.poll(&flow, screen: Self.idle, blocked: false, at: 1)
        #expect(flow.inFlight == nil)
        #expect(flow.lastAnswer == nil)
    }

    @Test("已回答卡片:至少顯示 4 秒;Agent 寫出文字後收起;只有工具步驟時留 30 秒(#213)")
    func answeredCardLifetime() {
        var (flow, _) = Self.answered()
        Self.poll(&flow, screen: Self.idle, blocked: false, at: 1)
        let anchor = [AnsweredCardAnchor.Row(id: "e1", showsText: true)]
        let withText = anchor + [.init(id: "e2", showsText: true)]
        let stepsOnly = anchor + [.init(id: "e2", showsText: false)]

        flow.refreshAnsweredCard(rows: withText, now: Self.t0.addingTimeInterval(2))
        #expect(flow.lastAnswer != nil)
        flow.refreshAnsweredCard(rows: stepsOnly, now: Self.t0.addingTimeInterval(10))
        #expect(flow.lastAnswer != nil)
        flow.refreshAnsweredCard(rows: stepsOnly, now: Self.t0.addingTimeInterval(31))
        #expect(flow.lastAnswer == nil)

        var (again, _) = Self.answered()
        Self.poll(&again, screen: Self.idle, blocked: false, at: 1)
        again.refreshAnsweredCard(rows: withText, now: Self.t0.addingTimeInterval(5))
        #expect(again.lastAnswer == nil)
    }

    // MARK: 期限與過時的 blocked

    @Test("同一個提示超過期限(12 秒):解鎖並提示可能沒送到;期限內仍鎖住")
    func deadline() {
        var (flow, _) = Self.answered()
        let early = Self.poll(&flow, screen: Self.permission, at: 12)
        #expect(flow.inFlight != nil)
        #expect(early.haptic == nil)
        let late = Self.poll(&flow, screen: Self.permission, at: 12.5)
        #expect(flow.inFlight == nil)
        #expect(flow.notice == .mayNotHaveArrived)
        #expect(late.haptic == .error)
    }

    @Test("讀不到畫面時同樣只看逾時")
    func deadlineWhenUnreadable() {
        var (flow, _) = Self.answered()
        Self.poll(&flow, screen: nil, at: 13)
        #expect(flow.inFlight == nil)
        #expect(flow.notice == .mayNotHaveArrived)
    }

    @Test("答完 12 秒內 blocked 但畫面不是選單:不冒通用鈕(#468),過了期限才冒")
    func staleBlockedWindow() {
        var (flow, _) = Self.answered()
        // 先結算掉已送達(畫面是選單以外、仍 blocked):期限內視為沒有提示
        Self.poll(&flow, screen: Self.idle, at: 3)
        #expect(flow.prompt?.kind != .unrecognized)
        #expect(flow.inFlight != nil || flow.lastAnswer != nil)
        Self.poll(&flow, screen: Self.idle, at: 13)
        #expect(flow.prompt?.kind == .unrecognized)
    }

    @Test("按鍵還沒送完而畫面重繪看不出選單:維持原卡片,不換成通用鈕(#468)")
    func keepsCardWhileSending() throws {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: Self.permission)
        let before = flow.prompt
        _ = flow.begin(answer: .option(try #require(before?.options.first)), isReadOnly: false)
        let outcome = Self.poll(&flow, screen: Self.idle, at: 1)
        #expect(flow.prompt == before)
        #expect(flow.inFlight != nil)
        #expect(outcome.agentBlocked)
    }

    @Test("答完的期限內讀不到畫面:不冒通用鈕")
    func staleWindowWhenUnreadable() {
        var (flow, _) = Self.answered()
        // 先讓畫面不是選單、blocked,設定過時期限並清掉提示
        Self.poll(&flow, screen: Self.idle, at: 2)
        var fresh = AnswerFlow(agentKind: "claude")
        Self.poll(&fresh, screen: Self.permission)
        let answer = PromptAnswer.option(fresh.prompt!.options[0])
        _ = fresh.begin(answer: answer, isReadOnly: false)
        _ = fresh.finish(answer, result: .sent(lastEntryID: nil, at: Self.t0))
        Self.poll(&fresh, screen: Self.idle, at: 1)  // 設定 staleBlockedUntil,卡片視為已送達
        #expect(fresh.prompt == nil)
        Self.poll(&fresh, screen: nil, at: 2)
        #expect(fresh.prompt == nil)
    }

    // MARK: 自訂回答

    static func typedFlow() throws -> (AnswerFlow, PromptOption) {
        var flow = AnswerFlow(agentKind: "claude")
        Self.poll(&flow, screen: question)
        let option = try #require(flow.prompt?.typedAnswerOption(agentKind: "claude"))
        return (flow, option)
    }

    @Test("開始自訂回答:收起草稿、輸入框清空;取消時放回草稿")
    func typedBeginAndCancel() throws {
        var (flow, option) = try Self.typedFlow()
        #expect(flow.isQuestionCard)
        #expect(flow.beginTyped(option, draft: "keep me") == "")
        #expect(flow.typed == option)
        #expect(flow.cancelTyped() == "keep me")
        #expect(flow.typed == nil)
        #expect(flow.cancelTyped() == nil)
    }

    @Test("自訂回答:打過字再清空才算取消(#127);剛進入的空輸入框不算")
    func typedClearingCancels() throws {
        var (flow, option) = try Self.typedFlow()
        _ = flow.beginTyped(option, draft: "old")
        #expect(flow.typedDraftChanged("") == nil)
        #expect(flow.typedDraftChanged("abc") == nil)
        #expect(flow.typedDraftChanged("") == "old")
        #expect(flow.typed == nil)
    }

    @Test("送出自訂回答:結束自訂回答放回草稿,接著送數字、文字、Enter")
    func typedSubmit() throws {
        var (flow, option) = try Self.typedFlow()
        _ = flow.beginTyped(option, draft: "old")
        guard case .send(let answer, let draft) = flow.submitTyped(option: option, text: "hello", isReadOnly: false) else {
            Issue.record("應該可以送出")
            return
        }
        #expect(draft == "old")
        #expect(flow.typed == nil)
        let begun = flow.begin(answer: answer, isReadOnly: false)
        let inputs = try #require(begun)
        #expect(inputs.contains(.text("hello")))
    }

    @Test("送出自訂回答時題目已變:文字留在輸入框並提示;失敗後可回到自訂回答保留打的字")
    func typedSubmitQuestionChanged() throws {
        var (flow, option) = try Self.typedFlow()
        _ = flow.beginTyped(option, draft: "")
        Self.poll(&flow, screen: Self.permission)  // 題目換了(自訂回答已被結束,這裡再補一次進入以覆蓋舊題目的情況)
        #expect(flow.typed == nil)

        var (again, again2) = try Self.typedFlow()
        _ = again.beginTyped(again2, draft: "")
        // 用不屬於這題的選項送出
        let foreign = PromptOption(number: 9, label: "Other", isCursor: false)
        let result = again.submitTyped(option: foreign, text: "typed", isReadOnly: false)
        #expect(result == .questionChanged(draft: "typed"))
        #expect(again.notice == .questionChanged)

        // 送出失敗後回到自訂回答
        var (retry, option3) = try Self.typedFlow()
        _ = retry.beginTyped(option3, draft: "")
        guard case .send(let answer, _) = retry.submitTyped(option: option3, text: "keep", isReadOnly: false) else { return }
        _ = retry.begin(answer: answer, isReadOnly: false)
        _ = retry.finish(answer, result: .failed)
        #expect(retry.resumeTypedAfterFailure(option: option3, text: "keep", currentDraft: "") == "keep")
        #expect(retry.typed == option3)
    }

    @Test("提示在終端機被回答掉:自訂回答結束,打到一半的字留在輸入框")
    func typedEndsWhenPromptGone() throws {
        var (flow, option) = try Self.typedFlow()
        _ = flow.beginTyped(option, draft: "before")
        let outcome = Self.poll(&flow, screen: Self.idle, blocked: false, at: 1, draft: "half typed")
        #expect(flow.typed == nil)
        #expect(outcome.draft == "before\nhalf typed")
    }

    @Test("打自訂答案時畫面暫時看不出選單:維持卡片與自訂回答")
    func typedSurvivesRedraw() throws {
        var (flow, option) = try Self.typedFlow()
        _ = flow.beginTyped(option, draft: "")
        let before = flow.prompt
        let outcome = Self.poll(&flow, screen: Self.idle, at: 1)
        #expect(flow.prompt == before)
        #expect(flow.typed == option)
        #expect(outcome.agentBlocked)
    }

    @Test("「Type something.」已在自訂回答時仍可點,送出中不可")
    func typedOptionState() throws {
        var (flow, option) = try Self.typedFlow()
        #expect(flow.optionState(for: option, isReadOnly: false) == .available)
        _ = flow.beginTyped(option, draft: "")
        #expect(flow.canBeginTyped(option))
        #expect(flow.beginTyped(option, draft: "x") == nil)
    }
}
