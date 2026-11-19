import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 在對話中回答「需要你」(行為規格 F8、§5、R-Q01–R-Q09)。herdr 走假主機;畫面是依規格手寫的(`PaneScreens`),
/// `pane.send_keys` 的回應不錄(`PromptReplies.keysAccepted`)。**不對任何真實 agent 送按鍵。**
@MainActor
@Suite("回答需要你")
struct ConversationAnswerTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID

    final class RecordingHaptics: Haptics {
        private(set) var played: [HapticFeedback] = []
        func play(_ feedback: HapticFeedback) { played.append(feedback) }
    }

    struct Setup {
        let host: RoutingHost
        let shell: LocalShellHost
        let model: ConversationModel
        let clock: TestClock
        let haptics: RecordingHaptics
        let sleeper: RecordingSleeper
    }

    static func setup(sleeper: RecordingSleeper = RecordingSleeper()) throws -> Setup {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let clock = TestClock()
        let haptics = RecordingHaptics()
        let model = ConversationModel(
            client: HerdrClient(channel: host, sleep: sleeper.sleep), transcripts: TranscriptReader(channel: host), paneID: paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(), clock: clock.clock,
            haptics: haptics, sleep: sleeper.sleep
        )
        return Setup(host: host, shell: shell, model: model, clock: clock, haptics: haptics, sleeper: sleeper)
    }

    static func snapshot(status: String, kind: String = "claude", session: Bool = true) -> FakeReply {
        ConversationModelTests.snapshot { agent in
            agent["agent_status"] = status
            agent["agent"] = kind
            if !session { agent.removeValue(forKey: "agent_session") }
        }
    }

    /// 一次輪詢：snapshot,接著讀畫面。
    static func expectPoll(_ setup: Setup, status: String = "blocked", kind: String = "claude", screen: String?) async {
        await setup.host.bridge.expect(bridge, reply: snapshot(status: status, kind: kind))
        if let screen { await setup.host.bridge.expect(bridge, reply: PaneScreens.read(screen)) }
    }

    static func keyRequests(_ setup: Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains(#""method":"pane.send_keys""#) }
    }

    static func paneReads(_ setup: Setup) async -> Int {
        await setup.host.bridge.executions.filter { $0.stdinText.contains(#""method":"pane.read""#) }.count
    }

    static func keys(_ list: [String]) -> String {
        let quoted = list.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"purrdr:pane.send_keys","method":"pane.send_keys","params":{"keys":[\#(quoted)],"pane_id":"w1:p6"}}"# + "\n"
    }

    // MARK: - 顯示

    @Test("blocked:讀 pane 畫面，顯示問題與選項")
    func blockedShowsPrompt() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")

        await setup.model.poll()

        #expect(setup.model.prompt?.question == "Do you want to proceed?")
        #expect(setup.model.prompt?.options.count == 3)
        #expect(await Self.paneReads(setup) == 1)
    }

    @Test("blocked 但畫面看不出選單：通用鈕的提示")
    func blockedWithoutMenuIsUnrecognized() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-idle")

        await setup.model.poll()

        #expect(setup.model.prompt?.kind == .unrecognized)
    }

    @Test("閒置且有 session 的 agent 不讀畫面(指令預算)")
    func idleWithSessionDoesNotReadScreen() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, status: "idle", screen: nil)

        await setup.model.poll()

        #expect(setup.model.prompt == nil)
        #expect(await Self.paneReads(setup) == 0)
    }

    @Test("閒置、還沒有 session(Claude 首次啟動):讀畫面，只認資料夾信任提示，並視為需要你")
    func idleTrustPromptIsBlocked() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle", session: false))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-trust"))

        await setup.model.poll()

        #expect(setup.model.prompt?.kind == .trust)
        #expect(setup.model.agentStatus == .blocked)
    }

    @Test("閒置、還沒有 session:對話中的編號清單不是提示")
    func idleNumberedListIsNotAPrompt() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle", session: false))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "Pick one?\n❯ 1. Yes\n  2. No\n"))

        await setup.model.poll()

        #expect(setup.model.prompt == nil)
        #expect(setup.model.agentStatus == .idle)
    }

    // MARK: - 作答

    @Test("作答：依 agent 規則送出按鍵(Claude 只送數字),選擇觸覺，鎖住其他選項")
    func answerSendsDigitOnlyForClaude() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let option = try #require(setup.model.prompt?.options[1])

        await setup.model.answer(.option(option))

        #expect(await Self.keyRequests(setup) == [Self.keys(["2"])])
        #expect(setup.haptics.played == [.selection])
        #expect(setup.model.answerInFlight == .option(option))
        #expect(setup.model.canAnswer(.option(option)) == false)
    }

    @Test("作答：Codex 送數字加 Enter")
    func answerSendsDigitAndEnterForCodex() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, kind: "codex", screen: "codex-command")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)

        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))

        #expect(await Self.keyRequests(setup) == [Self.keys(["1", "enter"])])
    }

    @Test("資料夾信任：Yes 送 down + enter(游標在 No, exit,單按 Enter 會關掉 Claude)")
    func trustAnswerUsesArrowKeys() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-trust")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let yes = try #require(setup.model.prompt?.options.first { $0.label == "Yes, I trust this folder" })

        await setup.model.answer(.option(yes))

        #expect(await Self.keyRequests(setup) == [Self.keys(["down", "enter"])])
    }

    @Test("編號 10 以上：顯示但不能作答，不送任何按鍵")
    func optionAboveNineIsDisabled() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-many-options")
        await setup.model.poll()
        let tenth = try #require(setup.model.prompt?.options.first { $0.number == 10 })

        #expect(setup.model.canAnswer(.option(tenth)) == false)
        await setup.model.answer(.option(tenth))

        #expect(await Self.keyRequests(setup).isEmpty)
        #expect(setup.haptics.played.isEmpty)
    }

    @Test("防重複：作答進行中的第二次點擊不送")
    func secondTapWhileInFlightIsIgnored() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.silent)
        // 第二次點擊若真的送出，主機也會收下(才看得出有沒有送)。
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let options = try #require(setup.model.prompt?.options)

        let first = Task { await setup.model.answer(.option(options[0])) }
        try await waitUntil { await Self.keyRequests(setup).count == 1 }
        await setup.model.answer(.option(options[2]))

        #expect(await Self.keyRequests(setup) == [Self.keys(["1"])])
        first.cancel()
    }

    // MARK: - 結果

    @Test("已送達：下次輪詢不再 blocked → 清除提示，記下選了什麼，成功觸覺")
    func deliveredWhenNoLongerBlocked() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))

        await Self.expectPoll(setup, status: "working", screen: nil)
        await setup.model.poll()

        #expect(setup.model.prompt == nil)
        #expect(setup.model.answerInFlight == nil)
        #expect(setup.model.lastAnswer == AnsweredPrompt(question: "Do you want to proceed?", choice: "Yes"))
        #expect(setup.haptics.played == [.selection, .success])
    }

    /// #213:「你選了：Cancel」曾在 Agent 輸出很多新內容後仍釘在對話底部。
    @Test("已回答卡片：Agent 繼續工作、對話紀錄多了新回覆後收起")
    func answeredCardHidesAfterAgentWritesMore() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-ask-review")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let cancel = try #require(setup.model.prompt?.options.first { $0.label == "Cancel" })
        await setup.model.answer(.option(cancel))

        await Self.expectPoll(setup, status: "working", screen: nil)
        await setup.model.poll()
        #expect(setup.model.lastAnswer == AnsweredPrompt(question: "Ready to submit your answers?", choice: "Cancel"))

        let replyLine = ConversationModelTests.fixtureLines[19]
            .replacingOccurrences(of: "00000000-0000-4000-8000-00000000001f", with: "00000000-0000-4000-8000-0000000000fa")
        try setup.shell.append(Data((replyLine + "\n").utf8), to: ConversationModelTests.transcriptPath)
        setup.clock.advance(by: AnsweredCardAnchor.minimumShowing)
        await Self.expectPoll(setup, status: "working", screen: nil)
        await setup.model.poll()

        #expect(setup.model.lastAnswer == nil)
    }

    /// #213 review:Agent 回答後幾秒內寫出工具步驟，卡片曾在判定送達的同一輪就收起，看不到「你選了」。
    @Test("已回答卡片：寫得快，判定送達那一輪對話紀錄已有新的工具步驟，卡片仍留著")
    func answeredCardStaysWhenStepsFollowQuickly() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-ask-review")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let cancel = try #require(setup.model.prompt?.options.first { $0.label == "Cancel" })
        await setup.model.answer(.option(cancel))

        let toolLine = ConversationModelTests.fixtureLines[20]
            .replacingOccurrences(of: "00000000-0000-4000-8000-000000000020", with: "00000000-0000-4000-8000-0000000000fb")
        try setup.shell.append(Data((toolLine + "\n").utf8), to: ConversationModelTests.transcriptPath)
        setup.clock.advance(by: 1)
        await Self.expectPoll(setup, status: "working", screen: nil)
        await setup.model.poll()

        #expect(setup.model.lastAnswer == AnsweredPrompt(question: "Ready to submit your answers?", choice: "Cancel"))
    }

    @Test("被取代：畫面上換成另一個提示(下一題)→ 解鎖，新問題不繼承鎖")
    func supersededByNextQuestion() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))

        await Self.expectPoll(setup, screen: "claude-ask-review")
        await setup.model.poll()

        #expect(setup.model.prompt?.question == "Ready to submit your answers?")
        #expect(setup.model.answerInFlight == nil)
        #expect(setup.model.lastAnswer?.choice == "Blue")
        #expect(setup.haptics.played == [.selection, .success])
    }

    @Test("同一提示還在：12 秒內等待;超過 → 逾時，恢復選項並提示可能沒送到，失敗觸覺")
    func sameMenuTimesOut() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let option = try #require(setup.model.prompt?.options.first)
        await setup.model.answer(.option(option))

        setup.clock.advance(by: 11)
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        #expect(setup.model.answerInFlight == .option(option))
        #expect(setup.model.answerNotice == nil)

        setup.clock.advance(by: 2)
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()

        #expect(setup.model.answerInFlight == nil)
        #expect(setup.model.answerNotice == .mayNotHaveArrived)
        #expect(setup.model.canAnswer(.option(option)))
        #expect(setup.haptics.played == [.selection, .error])
    }

    @Test("讀不到畫面：不當成新提示，也不判逾時以外的結果")
    func unreadableScreenKeepsWaiting() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        let option = try #require(setup.model.prompt?.options.first)
        await setup.model.answer(.option(option))

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.error("pane_not_found", "pane not found"))
        await setup.model.poll()

        #expect(setup.model.answerInFlight == .option(option))
        #expect(setup.model.prompt?.question == "Do you want to proceed?")
    }

    @Test("送不出按鍵：立刻解鎖並顯示錯誤，失敗觸覺")
    func sendFailureUnlocks() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, screen: "claude-bash")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.error("pane_not_found", "pane w1:p6 not found"))

        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))

        #expect(setup.model.answerInFlight == nil)
        #expect(setup.model.answerNotice == .sendFailed)
        #expect(setup.haptics.played == [.selection, .error])
    }

    @Test("作答後 0.4 秒與 1.2 秒再輪詢一次(下一題常緊接著出現)")
    func answerKicksTwoPolls() async throws {
        let sleeper = RecordingSleeper { $0 == .milliseconds(400) || $0 == .milliseconds(800) }
        let setup = try Self.setup(sleeper: sleeper)
        await Self.expectPoll(setup, screen: "claude-ask-question")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await Self.expectPoll(setup, screen: "claude-ask-review")
        await Self.expectPoll(setup, screen: "claude-ask-review")

        await setup.model.answer(.option(try #require(setup.model.prompt?.options.first)))
        try await waitUntil { await Self.paneReads(setup) == 3 }

        #expect(await sleeper.requested.filter { $0 < .seconds(1) } == [.milliseconds(400), .milliseconds(800)])
        #expect(setup.model.prompt?.question == "Ready to submit your answers?")
    }

    @Test("多選：勾選列只送數字，「繼續」送 right")
    func multiSelectToggleAndContinue() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, kind: "codex", screen: "claude-ask-multiselect")
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.option(try #require(setup.model.prompt?.options[1])))
        #expect(await Self.keyRequests(setup) == [Self.keys(["2"])])

        await Self.expectPoll(setup, kind: "codex", screen: "claude-ask-multiselect")
        setup.clock.advance(by: 13)
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.answer(.continueMultiSelect)

        #expect(await Self.keyRequests(setup).last == Self.keys(["right"]))
    }

    @Test("送出 prompt 時 agent 在等回答：立刻讀畫面找出問題")
    func needsAnswerOnSendReadsScreen() async throws {
        let setup = try Self.setup()
        await Self.expectPoll(setup, status: "idle", screen: nil)
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.error("agent_input_pending", "agent is waiting for input"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-trust"))
        setup.model.draft = "hello"

        await setup.model.send()

        #expect(setup.model.notice == .needsAnswer)
        #expect(setup.model.prompt?.kind == .trust)
    }
}

/// 建議選項的樣式(HIG 20.7:以樣式區分;破壞性選項不設為預設)。
@Suite("建議選項")
struct PromptOptionStyleTests {
    @Test("游標所在的選項是建議選項")
    func cursorOptionIsRecommended() throws {
        let prompt = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("claude-bash"), agentKind: "claude"))
        #expect(prompt.options.map(PromptOptionStyle.isRecommended) == [true, false, false])
    }

    @Test("游標停在「No, exit」/「No, quit」時不把它設為建議選項")
    func destructiveCursorIsNotRecommended() throws {
        let prompt = try #require(BlockedPromptParser.parse(screen: PaneScreens.text("claude-trust"), agentKind: "claude"))
        #expect(prompt.options.filter(PromptOptionStyle.isRecommended).isEmpty)
        let codex = try #require(BlockedPromptParser.parse(
            screen: PaneScreens.text("codex-trust").replacingOccurrences(of: "› 1. Yes, continue\n  2. No, quit", with: "  1. Yes, continue\n› 2. No, quit"),
            agentKind: "codex"))
        #expect(codex.options.filter(PromptOptionStyle.isRecommended).isEmpty)
    }
}
