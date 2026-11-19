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

    static func keyRequests(_ setup: Setup) async -> [String] {
        await setup.host.bridge.executions.map(\.stdinText).filter { $0.contains(#""method":"pane.send_keys""#) }
    }

    // MARK: - 標題列資訊

    /// workspace 名稱與標題不同 → 列出;資料夾與 workspace 同名 → 不重複;模型取顯示名、effort 加「effort」。
    @Test("標題列：狀態 + workspace、agent、模型、effort;資料夾與 workspace 重複時省略;選取中主機不列主機名")
    func headerSegments() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))

        await setup.model.poll()

        let header = setup.model.header
        #expect(header.status == .online)
        #expect(header.segments == ["garden-journal", "Claude Code", "Opus 5.5", "medium effort"])
        #expect(header.accessibilityText == "Online, garden-journal, Claude Code, Opus 5.5, medium effort")
    }

    @Test("標題列：非選取中主機時主機名排第一段;資料夾與標題、workspace 都不同時列出")
    func headerWithHostAndFolder() async throws {
        let setup = try Self.setup(hostName: "studio")
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.snapshot {
            $0["agent_status"] = "done"
            $0["cwd"] = "/Users/demo/Projects/garden-journal/web"
        })

        await setup.model.poll()

        #expect(setup.model.header.status == .done)
        #expect(setup.model.header.segments.first == "studio")
        #expect(setup.model.header.segments.last == "web")
    }

    @Test("標題列:/effort、/model 改過之後下一次輪詢立刻反映")
    func headerFollowsModelAndEffortCommands() async throws {
        let setup = try Self.setup()
        // 閒置的 Claude Code:每次輪詢都讀一次含 ANSI 的畫面找建議提示詞(#123),這裡沒有建議。
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.noSuggestionScreen)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.host.bridge.expect(Self.bridge, reply: ConversationModelTests.noSuggestionScreen)
        await setup.model.poll()

        // 以 fixture 第 4 行(使用者行)為底，換成兩則本地指令輸出。
        let lines = [
            ("00000000-0000-4000-8000-0000000000e1", "Set effort level to high"),
            ("00000000-0000-4000-8000-0000000000e2", "Set model to Sonnet 5 (claude-sonnet-5-0) for this session only"),
        ].map { uuid, text in
            Fixtures.transcriptLine(4) {
                $0["uuid"] = uuid
                $0["message"] = ["role": "user", "content": "<local-command-stdout>\(text)</local-command-stdout>"]
            }
        }
        try setup.shell.append(Data((lines.joined(separator: "\n") + "\n").utf8), to: ConversationModelTests.transcriptPath)
        await setup.model.poll()

        #expect(setup.model.header.segments == ["garden-journal", "Claude Code", "Sonnet 5.0", "high effort"])
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
    @Test("離線：不再保留斷線前的 working,停止不可用、不顯示停止鈕")
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
        #expect(!setup.model.showsStopButton)
    }

    // MARK: - 重新載入與停止

    /// #220:停止移到輸入列;強制結束在標題列的選單，只對 working 的 agent(「需要你」永不中斷)。
    @Test("標題列一律是「重新載入」;強制結束只在工作中可用，需要你、離線時不可用")
    func headerReloadAndForceQuitAvailability() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.model.poll()
        #expect(setup.model.headerAction == .reload)
        #expect(!setup.model.canForceQuit)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.headerAction == .reload)
        #expect(setup.model.canForceQuit)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PaneScreens.read("claude-bash"))
        await setup.model.poll()
        #expect(setup.model.headerAction == .reload)
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

    /// F6.7:畫面上是 2 秒前的 working,按下停止時 agent 已經在等你回答 → 一個按鍵都不送，並說明原因。
    @Test("停止：送前重讀到「需要你」→ 不送 Esc,提示先回答")
    func stopRefusesAgentThatNowNeedsYou() async throws {
        // 等待立刻結束，herdr 請求的期限除外。
        let setup = try Self.setup(sleeper: RecordingSleeper { $0 < HostCommandDeadline.standard })
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.canStop)

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.model.stop()

        #expect(await Self.keyRequests(setup).isEmpty)
        #expect(setup.model.notice == .interruptRefusedNeedsAnswer)
    }

    /// #220:工作中送出鈕變停止鈕;打了字就回到送出(工作中送出的 prompt 會排隊)。
    @Test("停止鈕：工作中且草稿空白才出現，有草稿時是送出")
    func stopButtonReplacesSendWhileWorking() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        await setup.model.poll()
        #expect(!setup.model.showsStopButton)

        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()
        #expect(setup.model.showsStopButton)

        setup.model.draft = "接著做"
        #expect(!setup.model.showsStopButton)
    }

    @Test("停止成功：不等下一次輪詢，停止鈕立刻換回送出")
    func stopSuccessReturnsToSendImmediately() async throws {
        let setup = try Self.setup(sleeper: RecordingSleeper { $0 < HostCommandDeadline.standard })
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await setup.model.stop()

        #expect(setup.model.notice == nil)
        #expect(!setup.model.showsStopButton)
        #expect(setup.model.header.status != .working)
    }

    /// #220:讀不到狀態不能當成功。
    @Test("停止：送出 Esc 後讀不到狀態 → 提示無法確認是否已停止")
    func stopUnreadableStatusShowsUnconfirmed() async throws {
        let setup = try Self.setup(sleeper: RecordingSleeper { $0 < HostCommandDeadline.standard })
        await Self.expectWorkingPoll(setup, screen: Self.writingScreen)
        await setup.model.poll()

        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await setup.host.bridge.expect(Self.bridge, reply: PromptReplies.keysAccepted)
        await setup.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        await setup.model.stop()

        #expect(await Self.keyRequests(setup).count == 1)
        #expect(setup.model.notice == .stopUnconfirmed)
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
        #expect(setup.model.notice == .interruptRefusedNeedsAnswer)
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
    @Test("工作中點陣:3×3;動畫時每一格亮度隨時間輪轉;Reduce Motion 時固定不變")
    func workingDotsRespectReduceMotion() {
        let first = WorkingDots.opacities(frame: 0, reduceMotion: false)
        let next = WorkingDots.opacities(frame: 1, reduceMotion: false)
        #expect(first.count == 9)
        #expect(first != next)

        let still = (0..<12).map { WorkingDots.opacities(frame: $0, reduceMotion: true) }
        #expect(still.count == 12)
        #expect(Set(still).count == 1)
        #expect(still[0].count == 9)
        #expect(still[0].allSatisfy { $0 > 0 })
    }

    @Test("標題列放不下時從後面整段拿掉：最長的在前，最短的只剩狀態")
    func headerVariantsDropWholeSegments() {
        let header = ConversationHeader(status: .working, segments: ["studio", "garden-journal", "Claude Code"])
        #expect(header.displayVariants == [
            "Working · studio · garden-journal · Claude Code",
            "Working · studio · garden-journal",
            "Working · studio",
            "Working",
        ])
    }
}
