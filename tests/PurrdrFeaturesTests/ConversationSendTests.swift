import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 在對話畫面送出 prompt(行為規格 F6.2、F6.5–F6.7、R-P05–R-P11)。herdr 走假主機，對話紀錄在本機暫存家目錄。
/// `agent.prompt` 的回應以錄製檔為底改動(見 `PromptDeliveryTests`)。
@MainActor
@Suite("對話送出")
struct ConversationSendTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID
    /// fixture 第 6 行是使用者打的字。
    static let typed = "幫我把 CSV 匯出整理一下 🧾"

    struct Setup {
        let host: RoutingHost
        let shell: LocalShellHost
        let model: ConversationModel
        let drafts: DraftStore
    }

    /// 建立畫面 model(client、對話紀錄讀取、草稿)。預設不帶圖片功能。
    typealias MakeModel = @MainActor (HerdrClient, TranscriptReader, DraftStore) -> ConversationModel

    static func setup(
        drafts: DraftStore = DraftStore(), sleeper: RecordingSleeper = RecordingSleeper(), make: MakeModel? = nil
    ) async throws -> Setup {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let client = HerdrClient(channel: host, sleep: sleeper.sleep)
        let model = make?(client, TranscriptReader(channel: host), drafts) ?? ConversationModel(
            client: client, transcripts: TranscriptReader(channel: host), paneID: paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: InMemoryConversationCache(),
            clock: TestClock().clock, drafts: drafts, sleep: sleeper.sleep
        )
        return Setup(host: host, shell: shell, model: model, drafts: drafts)
    }

    /// 開啟並讀完一次(輸入列在載入中不能送)。
    static func opened(
        drafts: DraftStore = DraftStore(), sleeper: RecordingSleeper = RecordingSleeper(), make: MakeModel? = nil
    ) async throws -> Setup {
        let setup = try await setup(drafts: drafts, sleeper: sleeper, make: make)
        await setup.host.bridge.expect(bridge, reply: snapshot())
        await setup.model.poll()
        return setup
    }

    static func snapshot(_ change: ((inout [String: Any]) -> Void)? = nil) -> FakeReply {
        ConversationModelTests.snapshot(change)
    }

    static let delivered = PromptReplies.prompted()

    /// 主機收下 prompt 後，對話紀錄出現一行新的使用者訊息(以 fixture 第 6 行為底換 uuid)。
    static func appendTypedLine(to setup: Setup, uuid: String = "00000000-0000-4000-8000-0000000000f8") throws {
        let line = ConversationModelTests.fixtureLines[6].replacingOccurrences(of: "00000000-0000-4000-8000-000000000008", with: uuid)
        try setup.shell.append(Data((line + "\n").utf8), to: ConversationModelTests.transcriptPath)
    }

    static func promptRequests(_ setup: Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains(#""method":"agent.prompt""#) }
    }

    // MARK: - 送出

    @Test("送出：先讀新鮮的 snapshot 重新確認目標 pane,再送;輸入框清空，立刻出現回音")
    func sendRereadsSnapshotAndEchoes() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: Self.delivered)
        setup.model.draft = "  多行\n第二行  "

        await setup.model.send()

        let requests = await setup.host.bridge.executions.map(\.stdinText)
        #expect(requests.count == 3)
        #expect(requests[1].contains(#""method":"session.snapshot""#))
        #expect(requests[2].contains(#""params":{"target":"w1:p6","text":"多行\n第二行","wait":"#))
        #expect(setup.model.draft == "")
        #expect(setup.model.echoes.map(\.text) == ["多行\n第二行"])
        #expect(setup.model.echoes.first?.state == .sent)
        #expect(setup.model.entries.last?.id == "echo:\(setup.model.echoes.first?.id ?? "")")
        #expect(setup.model.notice == nil)
    }

    @Test("回音：對話紀錄出現送出之後的同文字使用者行就消失(換成對話紀錄的那則)")
    func echoIsReplacedByTranscriptLine() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: Self.delivered)
        setup.model.draft = Self.typed
        await setup.model.send()
        #expect(setup.model.echoes.count == 1)

        try Self.appendTypedLine(to: setup)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.model.poll()

        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.entries.count == ConversationModelTests.fixtureItemCount + 1)
    }

    @Test("空白草稿不能送;送出中不能再送")
    func cannotSendBlankOrWhileSending() async throws {
        let setup = try await Self.opened()
        setup.model.draft = " \n "
        #expect(!setup.model.canSend)
        await setup.model.send()
        #expect(await Self.promptRequests(setup).isEmpty)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.silent)
        setup.model.draft = "第一則"
        let first = Task { await setup.model.send() }
        try await waitUntil { await Self.promptRequests(setup).count == 1 }
        #expect(setup.model.isSending)
        setup.model.draft = "第二則"
        #expect(!setup.model.canSend)
        await setup.model.send()
        #expect(await Self.promptRequests(setup).count == 1)
        #expect(setup.model.draft == "第二則")
        first.cancel()
    }

    @Test("載入中不能送")
    func cannotSendWhileLoading() async throws {
        let setup = try await Self.setup()
        setup.model.draft = "hi"
        #expect(!setup.model.canSend)
    }

    // MARK: - 失敗

    @Test("agent 在等回答：什麼都沒送出，草稿放回輸入框、回音拿掉、提示先回答")
    func needsAnswerRestoresDraft() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.error("agent_blocked", "agent is blocked"))
        setup.model.draft = "繼續"

        await setup.model.send()

        #expect(setup.model.draft == "繼續")
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.notice == .needsAnswer)
    }

    @Test("重讀 snapshot 發現 pane 已沒有 agent:不送，草稿放回")
    func agentGoneRestoresDraft() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.removeAgent(Self.paneID, in: &$0) })
        setup.model.draft = "還在嗎"

        await setup.model.send()

        #expect(await Self.promptRequests(setup).isEmpty)
        #expect(setup.model.draft == "還在嗎")
        #expect(setup.model.notice == .agentGone)
    }

    /// F5.1:session 換了 = pane 被回收成另一個聊天，原本要送的對象已經不在。
    @Test("重讀 snapshot 發現 session 已被取代：不送，草稿放回")
    func supersededSessionRestoresDraft() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot {
            $0["agent_session"] = ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": "00000000-0000-0000-0000-0000000000ff"]
        })
        setup.model.draft = "給舊聊天"

        await setup.model.send()

        #expect(await Self.promptRequests(setup).isEmpty)
        #expect(setup.model.draft == "給舊聊天")
        #expect(setup.model.notice == .superseded)
    }

    @Test("連線在送出時斷了：回音標示無法確認，草稿不放回(避免一鍵重送兩次);重試送同樣文字一次")
    func connectionLostKeepsEchoForRetry() async throws {
        let sleeper = RecordingSleeper { $0 == .seconds(28) }
        let setup = try await Self.opened(sleeper: sleeper)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.silent)
        setup.model.draft = "做完了嗎"

        await setup.model.send()

        #expect(setup.model.draft == "")
        let echo = try #require(setup.model.echoes.first)
        #expect(echo.state == .failed(.unconfirmed(.connectionLost)))
        #expect(setup.model.notice == .unconfirmed(.connectionLost))
        #expect(await Self.promptRequests(setup).count == 1)

        // 連點兩次重試：同一則訊息同時只能有一個重試在途(#100)。這次主機有回應，期限不再先到。
        await sleeper.stopFiring()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: Self.delivered)
        async let first: Void = setup.model.retry(echoID: echo.id)
        async let second: Void = setup.model.retry(echoID: echo.id)
        _ = await (first, second)

        let requests = await Self.promptRequests(setup)
        #expect(requests.count == 2)
        #expect(requests.last?.contains(#""text":"做完了嗎""#) == true)
        #expect(setup.model.echoes.first?.state == .sent)
        #expect(setup.model.notice == nil)
    }

    @Test("沒有反應：回音標示失敗並可重試")
    func noResponseMarksEchoFailed() async throws {
        let setup = try await Self.opened()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: .recorded("error.agent-wait-timeout.ndjson"))
        setup.model.draft = "hi"

        await setup.model.send()

        #expect(setup.model.echoes.first?.state == .failed(.noResponse))
        #expect(setup.model.notice == .noResponse)
    }

    /// R-P11:送出警告 2 秒就消失會誘發重送(#82)。
    @Test("送出警告：輪詢成功不清掉;對話紀錄確認任一回音時清掉;也可手動關閉")
    func noticeSurvivesPollingUntilConfirmed() async throws {
        let sleeper = RecordingSleeper { $0 == .seconds(28) }
        let setup = try await Self.opened(sleeper: sleeper)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.silent)
        setup.model.draft = Self.typed
        await setup.model.send()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.model.poll()
        #expect(setup.model.notice == .unconfirmed(.connectionLost))

        // 其實有送到：對話紀錄出現了這一行。
        try Self.appendTypedLine(to: setup)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.model.poll()
        #expect(setup.model.echoes.isEmpty)
        #expect(setup.model.notice == nil)
    }

    // MARK: - 草稿

    @Test("草稿：離開聊天再回來仍在(同一個 DraftStore)")
    func draftSurvivesLeavingChat() async throws {
        let drafts = DraftStore()
        let first = try await Self.setup(drafts: drafts)
        first.model.draft = "寫到一半"

        let second = try await Self.setup(drafts: drafts)

        #expect(second.model.draft == "寫到一半")
    }

    // MARK: - 中斷

    @Test("停止：只在 working 時可用;送一個 Esc,3 秒內沒停下就提示")
    func stopOnlyWhileWorking() async throws {
        let sleeper = RecordingSleeper { $0 == .milliseconds(500) }
        let setup = try await Self.opened(sleeper: sleeper)
        #expect(!setup.model.canStop)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot { $0["agent_status"] = "working" })
        await setup.model.poll()
        #expect(setup.model.canStop)

        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        for _ in 0..<6 { await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot { $0["agent_status"] = "working" }) }
        await setup.model.stop()

        #expect(setup.model.notice == .stillWorking)
        let keys = await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains("send_keys") }
        #expect(keys == [#"{"id":"purrdr:pane.send_keys","method":"pane.send_keys","params":{"keys":["esc"],"pane_id":"w1:p6"}}"# + "\n"])
    }

    @Test("blocked 的 agent 不能停止(中斷可能把問題關掉)")
    func cannotStopBlockedAgent() async throws {
        let setup = try await Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot { $0["agent_status"] = "blocked" })
        await setup.model.poll()

        #expect(!setup.model.canStop)
        await setup.model.stop()
        #expect(await setup.host.bridge.executions.count == 1)
    }
}
