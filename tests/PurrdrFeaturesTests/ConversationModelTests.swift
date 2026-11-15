import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 對話閱讀(行為規格 F5、§4、§10.5–10.6)。herdr 走假主機(錄製的 snapshot),對話紀錄腳本在本機對真實檔案執行
/// (`RoutingHost`),檔案內容是從真實 Claude Code 對話紀錄擷取的 fixture。
@MainActor
@Suite("對話閱讀")
struct ConversationModelTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = "w1:p6"
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let transcriptPath = ".claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"
    static let fixture = Fixtures.transcript()
    static let fixtureLines = Fixtures.transcriptLines()
    /// fixture 轉成的對話項目數(見 `ClaudeTranscriptParserTests.fixtureBecomesConversationItems`)。
    static let fixtureItemCount = 13

    static func snapshot(_ change: ((inout [String: Any]) -> Void)? = nil) -> FakeReply {
        guard let change else { return .recorded("session.snapshot.ndjson") }
        return .recorded("session.snapshot.ndjson") { SnapshotEdit.agent(paneID, in: &$0, change) }
    }

    struct Setup {
        let host: RoutingHost
        let shell: LocalShellHost
        let model: ConversationModel
        let clock: TestClock
        let cache: InMemoryConversationCache
    }

    static func setup(
        transcript: Data? = fixture, knownSessionID: String? = sessionID, cache: InMemoryConversationCache = InMemoryConversationCache(),
        openLines: Int = 300, pageLines: Int = 200
    ) throws -> Setup {
        let shell = try LocalShellHost.temporary()
        if let transcript { try shell.write(transcript, to: transcriptPath) }
        let host = RoutingHost(shell: shell)
        let clock = TestClock()
        let model = ConversationModel(
            client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host), paneID: paneID,
            knownSessionID: knownSessionID, cache: cache, clock: clock.clock, openLines: openLines, pageLines: pageLines
        )
        return Setup(host: host, shell: shell, model: model, clock: clock, cache: cache)
    }

    @Test("開啟：以 snapshot 的 session 找到對話紀錄，讀最後一個視窗並顯示")
    func openShowsConversationFromSession() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())

        await setup.model.poll()

        #expect(setup.model.phase == .ready)
        #expect(setup.model.items.count == Self.fixtureItemCount)
        #expect(setup.model.title == "整理植物照片的標籤")
        #expect(await setup.host.shellCommands.count == 2)
    }

    /// 行為規格 §4.7:之後只從游標讀新增的行，不重讀整個視窗。
    @Test("增量讀取：之後的輪詢只讀游標之後新增的行並接在後面")
    func laterPollsAppendNewLines() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.model.poll()

        // 以 fixture 第 6 行(使用者打的字)為底，換一個 uuid 當作新訊息。
        let newLine = Self.fixtureLines[6].replacingOccurrences(of: "00000000-0000-4000-8000-000000000008", with: "00000000-0000-4000-8000-0000000000f8")
        try setup.shell.append(Data((newLine + "\n").utf8), to: Self.transcriptPath)
        await setup.model.poll()

        #expect(setup.model.items.count == Self.fixtureItemCount + 1)
        guard case .user(let bubble) = setup.model.items.last else {
            Issue.record("最後一項應是新的使用者泡泡")
            return
        }
        #expect(bubble.text == "幫我把 CSV 匯出整理一下 🧾")
        let commands = await setup.host.shellCommands
        #expect(commands.count == 3)
        #expect(commands.last?.contains("tail -c +$(($2 + 1))") == true)
    }

    /// R-I02、F5.1:沒有 session id 就沒有東西可開，等待即可;絕不拿資料夾裡最新的 .jsonl 來猜。
    @Test("等待中：agent 還沒回報 session 時不開任何檔案")
    func waitsWithoutSessionAndNeverGuesses() async throws {
        let setup = try Self.setup(knownSessionID: nil)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot { $0.removeValue(forKey: "agent_session") })

        await setup.model.poll()

        #expect(setup.model.phase == .waitingForSession)
        #expect(setup.model.items.isEmpty)
        #expect(await setup.host.shellCommands.isEmpty)
    }

    /// R-I08:80 秒才判定缺少(新 Claude 約 48 秒才回報);agent 在等回答(blocked)時計時歸零。
    @Test("缺少：等待超過 80 秒才變缺少;blocked 期間計時歸零")
    func waitingBecomesMissingAfter80Seconds() async throws {
        let setup = try Self.setup(knownSessionID: nil)
        let noSession = Self.snapshot { $0.removeValue(forKey: "agent_session") }
        let blocked = Self.snapshot {
            $0.removeValue(forKey: "agent_session")
            $0["agent_status"] = "blocked"
        }
        for reply in [noSession, noSession, blocked, noSession, noSession] {
            await setup.host.bridge.expect(Self.bridge, reply: reply)
        }

        await setup.model.poll()
        setup.clock.advance(by: 79)
        await setup.model.poll()
        #expect(setup.model.phase == .waitingForSession)

        setup.clock.advance(by: 10)
        await setup.model.poll()
        #expect(setup.model.phase == .waitingForSession)

        setup.clock.advance(by: 79)
        await setup.model.poll()
        #expect(setup.model.phase == .waitingForSession)
        setup.clock.advance(by: 2)
        await setup.model.poll()
        #expect(setup.model.phase == .missingSession)
    }

    @Test("不支援：不是 Claude Code 的 agent 不讀對話紀錄")
    func otherAgentsAreUnsupported() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot { $0["agent"] = "amp" })

        await setup.model.poll()

        #expect(setup.model.phase == .unsupported)
        #expect(await setup.host.shellCommands.isEmpty)
    }

    /// R-I01、F5.1 第 4 點:herdr 會回收 pane id;新的 session 是另一個聊天，舊對話與游標都丟掉。
    @Test("Session 改變：丟掉舊對話與游標，改讀新 session 的對話紀錄")
    func sessionChangeReplacesConversation() async throws {
        let setup = try Self.setup()
        let otherSession = "00000000-0000-0000-0000-0000000000aa"
        try setup.shell.write(Data((Self.fixtureLines[6] + "\n").utf8), to: ".claude/projects/-Users-demo-Projects-garden-journal/\(otherSession).jsonl")
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot {
            $0["agent_session"] = ["source": "herdr:claude", "agent": "claude", "kind": "id", "value": otherSession]
        })

        await setup.model.poll()
        await setup.model.poll()

        #expect(setup.model.items.count == 1)
        #expect(setup.model.phase == .ready)
    }

    /// R-I09:新 session 在第一個 prompt 前可能沒有檔案 → 可用的空聊天，不是錯誤。
    @Test("檔案還不存在：空的聊天，不顯示錯誤")
    func absentTranscriptIsAnEmptyChat() async throws {
        let setup = try Self.setup(transcript: nil)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())

        await setup.model.poll()

        #expect(setup.model.phase == .ready)
        #expect(setup.model.items.isEmpty)
        #expect(setup.model.banner == nil)
    }

    /// R-I10:權限錯誤不是缺席，要說出來，否則對話永遠在等。
    @Test("檔案讀不到(權限):顯示無法讀取")
    func unreadableTranscriptShowsError() async throws {
        let setup = try Self.setup()
        let path = setup.shell.home.appending(path: Self.transcriptPath).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())

        await setup.model.poll()

        #expect(setup.model.banner == .unreadable)
    }

    /// F5.4、R-B05:往上翻以第一個視窗的起點為錨點讀上一頁，翻到 byte 0 為止;每則訊息恰好出現一次。
    @Test("往上翻：載入更早的訊息加在前面，到開頭為止")
    func loadOlderPrependsUntilStart() async throws {
        let setup = try Self.setup(openLines: 4, pageLines: 5)
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.model.poll()
        let opened = setup.model.items.count
        #expect(setup.model.older == .available)

        for _ in 0..<10 where setup.model.older == .available {
            await setup.model.loadOlder()
        }

        #expect(opened < Self.fixtureItemCount)
        #expect(setup.model.older == .reachedStart)
        #expect(setup.model.items.count == Self.fixtureItemCount)
        #expect(Set(setup.model.items.map(\.id)).count == Self.fixtureItemCount)
    }

    /// R-B16、#97:主機連不上時，以唯讀方式顯示上次的對話，並標示離線;只用屬於列表看到的 session 的快取。
    @Test("離線：連不上主機時顯示同一 session 的快取並標示離線")
    func offlineShowsCachedConversation() async throws {
        let cache = InMemoryConversationCache()
        let first = try Self.setup(cache: cache)
        await first.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await first.model.poll()

        let second = try Self.setup(transcript: nil, cache: cache)
        await second.host.bridge.expect(Self.bridge, reply: FakeReply(stderr: Data("ssh: connect to host timed out".utf8), exitCode: 255))
        await second.model.poll()

        #expect(second.model.isOffline)
        #expect(second.model.items.count == Self.fixtureItemCount)

        let other = try Self.setup(transcript: nil, knownSessionID: "00000000-0000-0000-0000-0000000000bb", cache: cache)
        await other.host.bridge.expect(Self.bridge, reply: FakeReply(exitCode: 255))
        await other.model.poll()
        #expect(other.model.items.isEmpty)
    }

    /// F5.3 第 1 點：列表傳來的 session 與快取相同 → 立刻顯示快取，之後從游標續讀。
    @Test("快取秒開：同一 session 的快取在讀主機之前就顯示，之後從游標續讀")
    func cachedConversationShowsImmediately() async throws {
        let cache = InMemoryConversationCache()
        let first = try Self.setup(cache: cache)
        await first.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await first.model.poll()

        let second = try Self.setup(cache: cache)
        await second.model.restoreFromCache()
        #expect(second.model.items.count == Self.fixtureItemCount)

        await second.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await second.model.poll()
        let commands = await second.host.shellCommands
        #expect(commands.count == 1)
        #expect(commands.first?.contains("tail -c +$(($2 + 1))") == true)
        #expect(second.model.items.count == Self.fixtureItemCount)
    }

    /// F5.13、R-H22:可見時每 20 秒回報一次;seq 以時鐘起算且單調遞增。
    @Test("在場回報：每 20 秒送 pane.report_metadata,seq 以時鐘起算且單調遞增")
    func presenceIsReportedEvery20Seconds() async throws {
        let setup = try Self.setup()
        await setup.host.bridge.expect(Self.bridge, reply: Self.snapshot())
        await setup.model.poll()
        await setup.host.bridge.expect(Self.bridge, reply: .recorded("pane.report-metadata.ndjson"))
        await setup.host.bridge.expect(Self.bridge, reply: .recorded("pane.report-metadata.ndjson"))

        let sleeper = Sleeper(blockAfter: 2)
        let task = Task { await setup.model.reportPresence(sleep: sleeper.sleep) }
        defer { task.cancel() }
        try await waitUntil { await sleeper.durations.count == 2 }

        let requests = await setup.host.bridge.executions.dropFirst().map(\.stdinText)
        #expect(await sleeper.durations == [.seconds(20), .seconds(20)])
        #expect(requests.count == 2)
        let now = UInt64(setup.clock.now.timeIntervalSince1970 * 1000)
        #expect(requests.first?.contains(#""seq":\#(now),"#) == true)
        #expect(requests.last?.contains(#""seq":\#(now + 1),"#) == true)
        #expect(requests.first?.contains(#""tokens":{"model":"Opus 5.5","phone":"on"}"#) == true)
    }
}

/// 可控制的時鐘。
@MainActor
final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_794_614_400)

    func advance(by seconds: TimeInterval) { now += seconds }

    var clock: ConversationClock {
        ConversationClock(now: { MainActor.assumeIsolated { self.now } })
    }
}
