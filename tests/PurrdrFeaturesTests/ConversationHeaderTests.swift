import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 對話標題列資訊、重新載入與停止、工作中指示(#44;行為規格 F5.7、F5.11、F6.7)。
/// herdr 走假主機(錄製的 snapshot 改動狀態),畫面是依規格手寫的;**不對任何真實 agent 送按鍵。**
@MainActor
@Suite("對話標題列與工作中指示")
struct ConversationHeaderTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = ConversationModelTests.paneID

    struct Setup {
        let host: RoutingHost
        let shell: LocalShellHost
        let model: ConversationModel
        let clock: TestClock
        let cache: InMemoryConversationCache
    }

    static func setup(hostName: String? = nil, sleeper: RecordingSleeper = RecordingSleeper()) throws -> Setup {
        let shell = try LocalShellHost.temporary()
        try shell.write(ConversationModelTests.fixture, to: ConversationModelTests.transcriptPath)
        let host = RoutingHost(shell: shell)
        let clock = TestClock()
        let cache = InMemoryConversationCache()
        let model = ConversationModel(
            client: HerdrClient(channel: host, sleep: sleeper.sleep), transcripts: TranscriptReader(channel: host), paneID: paneID,
            knownSessionID: ConversationModelTests.sessionID, cache: cache, clock: clock.clock, hostName: { hostName }, sleep: sleeper.sleep
        )
        return Setup(host: host, shell: shell, model: model, clock: clock, cache: cache)
    }

    static func snapshot(status: String) -> FakeReply {
        ConversationModelTests.snapshot { $0["agent_status"] = status }
    }

    /// 一次 working 的輪詢:snapshot,接著讀一次畫面(即時預覽與背景 agents 窗格共用)。
    static func expectWorkingPoll(_ setup: Setup, screen: String) async {
        await setup.host.bridge.expect(bridge, reply: snapshot(status: "working"))
        await setup.host.bridge.expect(bridge, reply: PaneScreens.read(text: screen))
    }

    static let writingScreen = """
        ⏺ The photo tags are now grouped by season, and the untagged ones
          are listed at the end so they are easy to find.

        ✻ Pondering… (12s · esc to interrupt)
        ❯
        """

    /// 停止的逾時(10 秒)以外的等待都立刻結束：確認迴圈、「已停止」的收起時間。
    static func shortWaitsFire() -> RecordingSleeper {
        RecordingSleeper { $0 < ConversationModel.stopTimeout }
    }

    static func keyRequests(_ setup: Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains(#""method":"pane.send_keys""#) }
    }

    // MARK: - 標題列資訊

    /// #270(原型 purrdr-screens 定案版):標題是 workspace 名稱，副標只有狀態與主機名;模型、effort、資料夾不再放副標。
    @Test("標題列：標題是 workspace 名稱，副標是狀態(沒有主機名時只有狀態)")
    func headerShowsWorkspaceAndStatus() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))

        await setup.model.poll()

        let header = setup.model.header
        #expect(header.title == "garden-journal")
        #expect(header.status == .online)
        #expect(header.segments == [])
        #expect(header.accessibilityText == "garden-journal, Online")
    }

    @Test("標題列：副標是狀態與主機名;VoiceOver 念 workspace、狀態、主機")
    func headerWithHost() async throws {
        let setup = try Self.setup(hostName: "studio")
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot {
            $0["agent_status"] = "done"
            $0["cwd"] = "/Users/demo/Projects/garden-journal/web"
        })

        await setup.model.poll()

        #expect(setup.model.header.status == .done)
        #expect(setup.model.header.segments == ["studio"])
        #expect(setup.model.header.accessibilityText == "garden-journal, Done, studio")
    }

    @Test("標題列：還沒讀到 Agent 時標題退回聊天標題")
    func headerTitleBeforeFirstPoll() throws {
        let setup = try Self.setup(hostName: "studio")
        #expect(setup.model.header.title == setup.model.title)
    }

    @Test("標題列：連不上主機 → 離線")
    func headerOffline() async throws {
        let setup = try Self.setup()
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        // 連續兩次失敗(第一次靜默重試，R-B11)才算連不上。
        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()
        await setup.model.poll()

        #expect(setup.model.header.status == .offline)
        #expect(!setup.model.showsWorkingIndicator)
    }

    /// #220:斷線前的 working 已過時，停止鈕不能留著讓人按。
    @Test("離線：不再保留斷線前的 working,停止與強制結束都不可用")
    func offlineDropsStaleWorkingAndStop() async throws {
        let setup = try Self.setup()
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.canStop)

        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()
        await setup.model.poll()

        #expect(setup.model.agentStatus != .working)
        #expect(!setup.model.canStop)
        #expect(!setup.model.canForceQuit)
        // 斷線前在工作：離線橫幅說明重新連上後才能停止;連上後拿掉。
        #expect(setup.model.stopNeedsReconnect)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(!setup.model.stopNeedsReconnect)
        #expect(setup.model.canStop)
    }

    @Test("離線：斷線前不在工作 → 橫幅不提停止")
    func offlineWhileIdleDoesNotMentionStop() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.model.poll()
        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()
        await setup.model.poll()

        #expect(setup.model.isOffline)
        #expect(!setup.model.stopNeedsReconnect)
    }

    /// #371:對照 `ConversationUITests` 刪掉的斷網 UI 測試(「需要你」的 agent、沒有對話紀錄的 Codex):
    /// 版面在斷網時仍可操作是 UI 煙霧測試的事，這裡只留下資料面的行為。
    @Test("離線：「需要你」的 agent 斷線後顯示離線橫幅、保留畫面上的內容")
    func offlineWhileBlockedKeepsItemsAndShowsBanner() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.noSuggestionScreen)
        await setup.model.poll()
        let before = setup.model.items.count
        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()

        #expect(setup.model.isOffline)
        #expect(setup.model.banner == .offline)
        #expect(setup.model.items.count == before, "斷線期間保留畫面上的內容")
    }

    @Test("離線：沒有對話紀錄、工作中的 Codex 斷線後顯示離線橫幅，停止要等重新連上")
    func offlineWhileCodexWorksShowsBanner() async throws {
        let setup = try ConversationModelTests.setup(transcript: nil, knownSessionID: nil)
        let codex = ConversationModelTests.snapshot { agent in
            agent["agent_status"] = "working"
            agent["agent"] = "codex"
            agent.removeValue(forKey: "agent_session")
        }
        await setup.host.bridge.expect(Self.bridge, reply: codex)
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: Self.writingScreen))
        await setup.model.poll()
        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()

        #expect(setup.model.isOffline)
        #expect(setup.model.banner == .offline)
        #expect(setup.model.stopNeedsReconnect)
    }

    // MARK: - 重新載入與停止

    /// #220:強制結束只對 working 的 agent(「需要你」永不中斷);離線時斷線前的 working 已過時。
    @Test("強制結束：只在工作中可用，需要你、離線時不可用")
    func forceQuitAvailability() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.model.poll()
        #expect(!setup.model.canForceQuit)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.canForceQuit)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()
        #expect(!setup.model.canForceQuit)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()
        await setup.model.poll()
        #expect(!setup.model.canForceQuit)
    }

    @Test("重新載入：清掉這個聊天的快取與游標並重讀(重新定位、讀視窗)")
    func reloadClearsCacheAndRereads() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.model.poll()
        #expect(await setup.cache.load(chatKey: Self.paneID) != nil)
        let before = await setup.host.shellCommands.count

        // 主機上的對話紀錄被換掉(只剩前 10 行):重新載入要讀到新內容，而不是從舊游標續讀。
        let replaced = Data((ConversationModelTests.fixtureLines.prefix(10).joined(separator: "\n") + "\n").utf8)
        try setup.shell.write(replaced, to: ConversationModelTests.transcriptPath)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.model.reload()

        let commands = await setup.host.shellCommands
        #expect(commands.count == before + 2)
        #expect(setup.model.items.count < ConversationModelTests.fixtureItemCount)
        #expect(await setup.cache.load(chatKey: Self.paneID)?.cursor == replaced.count)
    }

    /// F6.7:畫面上是 2 秒前的 working,按下停止時 agent 已經在等你回答 → 一個按鍵都不送，在停止列說明原因(#220)。
    @Test("停止：送前重讀到「需要你」→ 不送 Esc,停止列提示先回答")
    func stopRefusesAgentThatNowNeedsYou() async throws {
        // 等待立刻結束，herdr 請求的期限除外。
        let setup = try Self.setup(sleeper: Self.shortWaitsFire())
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.canStop)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.stop()

        #expect(await Self.keyRequests(setup).isEmpty)
        #expect(setup.model.stopPhase == .needsAnswer)
        #expect(setup.model.notice == nil)
        #expect(setup.model.showsStopBar)
    }

    @Test("停止列的「需要你」:仍在需要你時留著，agent 不再需要你就收起")
    func needsAnswerResultFollowsBlocked() async throws {
        let setup = try Self.setup(sleeper: Self.shortWaitsFire())
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.model.stop()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()
        #expect(setup.model.stopPhase == .needsAnswer)
        #expect(setup.model.showsStopBar)
        // 停止列只剩「需要你」的結果：輸入框上方這一樣是需要你，不是工作中。
        #expect(setup.model.topAccessory == .needsYou)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "❯ "))
        await setup.model.poll()
        #expect(setup.model.stopPhase == nil)
        #expect(!setup.model.showsStopBar)
    }

    @Test("輸入框上方一次只一樣：停止列(含已停止的結果)佔「工作中」,建議卡等它收起才出現")
    func stopBarHoldsWorkingSlotOverSuggestion() async throws {
        // 「已停止」的 2 秒永遠不到，只有確認迴圈的 500ms 會到。
        let setup = try Self.setup(sleeper: RecordingSleeper { $0 == .milliseconds(500) })
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.model.stop()
        #expect(setup.model.stopPhase == .stopped)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: ConversationSuggestionTests.ansiScreen("suggestion"))
        await setup.model.poll()
        #expect(setup.model.suggestion == "add subtract to calc.py")
        #expect(setup.model.showsStopBar)
        #expect(setup.model.topAccessory == .working)

        setup.model.dismissStopResult()
        #expect(!setup.model.showsStopBar)
        #expect(setup.model.topAccessory == .suggestion("add subtract to calc.py"))
    }

    @Test("停止成功：不等下一次輪詢，立刻換成停下後的狀態(停止不再可用)")
    func stopSuccessUpdatesStatusImmediately() async throws {
        let setup = try Self.setup(sleeper: Self.shortWaitsFire())
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.model.stop()

        #expect(setup.model.notice == nil)
        #expect(setup.model.agentStatus == .idle)
        #expect(!setup.model.canStop)
        // 「已停止」2 秒後自動收起(這裡的 2 秒立刻到)。
        for _ in 0..<2000 where setup.model.stopPhase != nil {
            await Task.yield()
        }
        #expect(setup.model.stopPhase == nil)
        #expect(!setup.model.showsStopBar)
    }

    @Test("已停止：收起前 agent 又開始工作 → 立刻換回停止鈕，不等 2 秒")
    func stoppedResultGivesWayWhenWorkingAgain() async throws {
        // 「已停止」的 2 秒永遠不到，只有確認迴圈的 500ms 會到。
        let setup = try Self.setup(sleeper: RecordingSleeper { $0 == .milliseconds(500) })
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        let stopping = Task { await setup.model.stop() }
        for _ in 0..<2000 where setup.model.stopPhase != .stopped {
            await Task.yield()
        }
        #expect(setup.model.stopPhase == .stopped)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.stopPhase == nil)
        #expect(setup.model.canStop)
        stopping.cancel()
        await stopping.value
    }

    /// #220:讀不到狀態不能當成功。
    @Test("停止：送出 Esc 後讀不到狀態 → 停止列顯示無法確認(不是已停止)")
    func stopUnreadableStatusShowsUnconfirmed() async throws {
        let setup = try Self.setup(sleeper: Self.shortWaitsFire())
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        await setup.model.stop()

        #expect(await Self.keyRequests(setup).count == 1)
        #expect(setup.model.stopPhase == .unconfirmed)
        #expect(setup.model.showsStopBar)
    }

    // MARK: - 停止列(#220)

    @Test("停止列：工作中出現;不在工作中、離線時沒有")
    func stopBarFollowsWorking() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.model.poll()
        #expect(!setup.model.showsStopBar)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.showsStopBar)
        #expect(setup.model.stopPhase == nil)

        for _ in 0..<2 {
            await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        }
        await setup.model.poll()
        await setup.model.poll()
        #expect(!setup.model.showsStopBar)
    }

    @Test("停止中：結果出來前是停止中、不能重按;已停止顯示一下，2 秒後收起")
    func stoppingThenStoppedCollapses() async throws {
        // 「已停止」的 2 秒不立刻結束，才看得到它。
        let sleeper = RecordingSleeper { $0 == .milliseconds(500) }
        let setup = try Self.setup(sleeper: sleeper)
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        let stopping = Task { await setup.model.stop() }
        var phases: [StopPhase?] = []
        for _ in 0..<2000 where setup.model.stopPhase != .stopped {
            if phases.last != setup.model.stopPhase { phases.append(setup.model.stopPhase) }
            if setup.model.stopPhase == .stopping { #expect(!setup.model.canStop) }
            await Task.yield()
        }
        #expect(phases.contains(.stopping))
        #expect(setup.model.stopPhase == .stopped)
        #expect(setup.model.showsStopBar)
        await stopping.value
        // 收起在另一個 task 等 2 秒(可被再次工作取消)。
        for _ in 0..<2000 where await !sleeper.requested.contains(.seconds(2)) {
            await Task.yield()
        }
        #expect(await sleeper.requested.contains(.seconds(2)))
        #expect(setup.model.stopPhase == .stopped)
    }

    @Test("停止：送不出 Esc → 停止列顯示送不出;關閉後收起")
    func stopKeysFailShowsFailed() async throws {
        let setup = try Self.setup(sleeper: Self.shortWaitsFire())
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        await setup.model.stop()

        #expect(setup.model.stopPhase == .failed)
        #expect(setup.model.notice == nil)
        setup.model.dismissStopResult()
        #expect(setup.model.stopPhase == nil)
    }

    @Test("停止：10 秒都沒有結果 → 仍在工作;agent 之後不在工作就收起")
    func stopTimesOutAsStillWorking() async throws {
        // 確認迴圈的 500ms 永遠不到，只有 10 秒的逾時會到。
        let setup = try Self.setup(sleeper: RecordingSleeper { $0 == ConversationModel.stopTimeout })
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.stop()
        #expect(setup.model.stopPhase == .stillWorking)
        #expect(!setup.model.isStopping)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "❯ "))
        await setup.model.poll()
        #expect(setup.model.stopPhase == nil)
        #expect(!setup.model.showsStopBar)
    }

    @Test("強制結束：送前重讀到「需要你」→ 不送 ctrl+c")
    func forceQuitRefusesAgentThatNowNeedsYou() async throws {
        let setup = try Self.setup()
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.forceQuit()

        #expect(await Self.keyRequests(setup).isEmpty)
        #expect(setup.model.stopPhase == .needsAnswer)
        #expect(setup.model.notice == nil)
    }

    @Test("強制結束：送不出 Ctrl-C → 停止列顯示送不出;agent 不在工作就收起")
    func forceQuitKeysFailShowsOnStopBar() async throws {
        let setup = try Self.setup()
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        await setup.model.forceQuit()
        #expect(setup.model.stopPhase == .forceQuitFailed)
        #expect(setup.model.notice == nil)
        #expect(setup.model.showsStopBar)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "❯ "))
        await setup.model.poll()
        #expect(setup.model.stopPhase == nil)
    }

    // MARK: - 工作中指示

    @Test("工作中指示：working 時出現，經過時間從出現起算;擷取到散文時有即時預覽;停止工作就消失")
    func workingIndicatorAndLivePreview() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.model.poll()
        #expect(!setup.model.showsWorkingIndicator)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        let start = setup.clock.now
        #expect(setup.model.showsWorkingIndicator)
        #expect(setup.model.workingSince == start)
        #expect(setup.model.livePreview == "The photo tags are now grouped by season, and the untagged ones are listed at the end so they are easy to find.")

        setup.clock.advance(by: 30)
        await Self.expectWorkingPoll(setup, screen: "✻ Pondering… (esc to interrupt)\n❯ ")
        await setup.model.poll()
        #expect(setup.model.workingSince == start)
        #expect(setup.model.livePreview == nil)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read(text: "❯ "))
        await setup.model.poll()
        #expect(!setup.model.showsWorkingIndicator)
        #expect(setup.model.workingSince == nil)
        #expect(setup.model.livePreview == nil)
    }

    /// #208:畫面上最後一段散文寫進對話紀錄後，撰寫中預覽不再重複顯示它(換行與全形標點不同也算同一段)。
    @Test("即時預覽：同一段已寫入對話紀錄就不再顯示")
    func livePreviewHidesTextAlreadyInTranscript() async throws {
        let setup = try Self.setup()
        let screen = """
            ⏺ #173 改了主機服務，但主機服務的 Release 要等 Developer ID 憑證放
              進 GitHub(上架檢查表 3A),所以這次只發 app 的 TestFlight,主機服務先
              不發行。

            ✻ Pondering… (2m 32s · esc to interrupt)
            ❯
            """
        await Self.expectWorkingPoll(setup, screen: screen)
        await setup.model.poll()
        #expect(setup.model.livePreview?.hasPrefix("#173 改了主機服務") == true)

        let reply = "#173 改了主機服務，但主機服務的 Release 要等 Developer ID 憑證放進 GitHub（上架檢查表 3A），所以這次只發 app 的 TestFlight，主機服務先不發行。"
        let replyLine = ConversationModelTests.fixtureLines[19]
            .replacingOccurrences(of: "收到，備註的換行也一起處理。", with: reply)
            .replacingOccurrences(of: "00000000-0000-4000-8000-00000000001f", with: "00000000-0000-4000-8000-0000000000f9")
        try setup.shell.append(Data((replyLine + "\n").utf8), to: ConversationModelTests.transcriptPath)
        setup.clock.advance(by: 6)
        await Self.expectWorkingPoll(setup, screen: screen)
        await setup.model.poll()

        #expect(setup.model.showsWorkingIndicator)
        #expect(setup.model.livePreview == nil)
    }

    @Test("經過時間：12s、11m 43s、1h 5m")
    func elapsedText() {
        #expect(WorkingElapsed.text(seconds: 0) == "0s")
        #expect(WorkingElapsed.text(seconds: 12) == "12s")
        #expect(WorkingElapsed.text(seconds: 11 * 60 + 43) == "11m 43s")
        #expect(WorkingElapsed.text(seconds: 3600 + 5 * 60 + 59) == "1h 5m")
    }

    /// HIG 20.4/20.2:Reduce Motion 時停用指示動畫(點陣固定不動，仍看得出是指示)。
    @Test("標題列放不下時從後面整段拿掉：最長的在前，最短的只剩狀態")
    func headerVariantsDropWholeSegments() {
        let header = ConversationHeader(title: "garden-journal", status: .working, segments: ["studio"])
        #expect(header.displayVariants == ["Working · studio", "Working"])
    }
}
