import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天畫面從主機更新來源取得 Agent 狀態，不自己讀快照(#163)。主機更新來源與聊天共用同一條假連線，
/// 所以送出的 `session.snapshot` 只來自主機更新來源(連上讀一次、訂閱開始再讀一次、之後每個事件一次)。
@MainActor
@Suite("聊天畫面讀主機更新來源")
struct ConversationHostUpdatesTests {
    static let paneID = "w1:p6"
    static let started = Fixtures.data("events.subscribe.started.ndjson")

    static func snapshot(_ status: String) -> Data {
        Fixtures.modifiedLine("session.snapshot.ndjson") { SnapshotEdit.agent(paneID, in: &$0) { $0["agent_status"] = status } }
    }

    static func paneRead(screen name: String) -> Data {
        Fixtures.modifiedLine("pane.read.visible.ndjson") { response in
            guard var result = response["result"] as? [String: Any], var read = result["read"] as? [String: Any] else { return }
            read["text"] = PaneScreens.text(name)
            result["read"] = read
            response["result"] = result
        }
    }

    static func count(_ method: String, in connection: FakeHostConnection) async -> Int {
        await HostUpdatesTests.methods(connection).filter { $0 == method }.count
    }

    /// 主機更新來源連上並開始訂閱(已送出 快照、訂閱、對帳快照 三個請求)。之後 `snapshots` 依序回應事件觸發的讀取。
    static func liveUpdates(
        _ connection: FakeHostConnection, initial status: String, later snapshots: [String] = []
    ) async throws -> (HostUpdates, Task<Void, Never>) {
        await connection.expect("session.snapshot", reply: snapshot(status))
        await connection.expect("events.subscribe", reply: started)
        await connection.expect("session.snapshot", reply: snapshot(status))
        for later in snapshots { await connection.expect("session.snapshot", reply: snapshot(later)) }
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: RecordingSleeper().sleep)
        let task = Task { await updates.liveUpdates.attach() }
        try await waitUntil { await connection.requests.count == 3 }
        // 同步點(#324):訂閱收到 ack 並對帳完才算連上;聊天只有這時才不自己讀快照，不能靠等一段時間。
        try await waitUntil { await MainActor.run { updates.isSubscribed } }
        return (updates, task)
    }

    static func conversation(_ connection: FakeHostConnection, updates: HostUpdates) -> ConversationModel {
        ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: paneID,
            knownSessionID: nil, cache: InMemoryConversationCache(), clock: TestClock().clock, updates: updates)
    }

    @Test("閒置與工作中：聊天畫面輪詢好幾輪都不送快照請求", arguments: ["idle", "working"])
    func pollingSendsNoSnapshotRequests(status: String) async throws {
        let connection = FakeHostConnection()
        let (updates, updatesTask) = try await Self.liveUpdates(connection, initial: status)
        defer { updatesTask.cancel() }
        let model = Self.conversation(connection, updates: updates)
        let ticks = TickSleeper()

        let chat = Task { await model.run(sleep: ticks.sleep) }
        try await waitUntil { await ticks.intervals.count >= 5 }
        chat.cancel()
        await chat.value

        #expect(await Self.count("session.snapshot", in: connection) == 2)
        #expect(model.agentStatus == AgentStatus(rawValue: status))
    }

    @Test("聊天畫面可見期間要求連線快速偵測斷線(不讀快照時靠 keepalive／心跳發現離線);離開後結束")
    func visibleChatRequestsQuickDisconnectDetection() async throws {
        let connection = FakeHostConnection()
        let (updates, updatesTask) = try await Self.liveUpdates(connection, initial: "idle")
        defer { updatesTask.cancel() }
        let model = Self.conversation(connection, updates: updates)
        let ticks = TickSleeper()

        let chat = Task { await model.run(sleep: ticks.sleep) }
        try await waitUntil { await ticks.intervals.count >= 2 }
        let duringRun = await connection.quickDetectionRequests
        chat.cancel()
        await chat.value

        #expect(duringRun == 1)
        #expect(await connection.quickDetectionRequests == 0)
    }

    @Test("需要你：狀態事件一到，聊天畫面立刻更新，不等下一輪")
    func statusEventUpdatesConversationWithoutWaiting() async throws {
        let connection = FakeHostConnection()
        let (updates, updatesTask) = try await Self.liveUpdates(connection, initial: "idle", later: ["blocked"])
        defer { updatesTask.cancel() }
        for _ in 0..<5 { await connection.expect("pane.read", reply: Self.paneRead(screen: "claude-ask-question")) }
        let model = Self.conversation(connection, updates: updates)
        let neverFires = RecordingSleeper()
        let chat = Task { await model.run(sleep: neverFires.sleep) }
        defer { chat.cancel() }
        try await waitUntil { await MainActor.run { model.agentStatus == .idle } }

        await connection.send(event: HostUpdatesTests.statusChanged(Self.paneID, status: "blocked"), toSubscription: 0)

        // 提問卡的畫面讀取排在讀對話紀錄之後(#356),狀態變了之後才出現。
        try await waitUntil { await MainActor.run { model.agentStatus == .blocked && model.prompt != nil } }
        #expect(await Self.count("session.snapshot", in: connection) == 3)
    }

    /// 例外快速路徑：多題問答期間 herdr 一直回報 blocked、沒有事件;每 2 秒讀畫面確認題目換了沒有，不讀快照。
    @Test("例外：一直 blocked 沒有事件時每 2 秒讀畫面，不讀快照")
    func blockedWithoutEventsKeepsReadingScreen() async throws {
        let connection = FakeHostConnection()
        let (updates, updatesTask) = try await Self.liveUpdates(connection, initial: "blocked")
        defer { updatesTask.cancel() }
        for _ in 0..<40 { await connection.expect("pane.read", reply: Self.paneRead(screen: "claude-ask-question")) }
        let model = Self.conversation(connection, updates: updates)
        let ticks = TickSleeper()

        let chat = Task { await model.run(sleep: ticks.sleep) }
        try await waitUntil { await ticks.intervals.count >= 5 }
        chat.cancel()
        await chat.value

        #expect(await ticks.intervals.allSatisfy { $0 == .seconds(2) })
        #expect(await Self.count("pane.read", in: connection) >= 5)
        #expect(await Self.count("session.snapshot", in: connection) == 2)
        #expect(model.prompt != nil)
    }

    /// 例外快速路徑：herdr 在背景 agent 執行時回報 idle(commit 0a3b0d7);窗格還有執行中的列就每 2 秒讀畫面。
    @Test("例外：背景 agent 執行中 herdr 回報 idle,仍每 2 秒讀畫面，不讀快照")
    func idleWithRunningBackgroundAgentsKeepsReadingScreen() async throws {
        let connection = FakeHostConnection()
        let (updates, updatesTask) = try await Self.liveUpdates(connection, initial: "working", later: ["idle"])
        defer { updatesTask.cancel() }
        for _ in 0..<60 { await connection.expect("pane.read", reply: Fixtures.data("pane.read.agents-pane.ndjson")) }
        let model = Self.conversation(connection, updates: updates)
        let ticks = TickSleeper()
        let chat = Task { await model.run(sleep: ticks.sleep) }
        try await waitUntil { await MainActor.run { model.agentsPane != nil } }

        await connection.send(event: HostUpdatesTests.statusChanged(Self.paneID, status: "idle"), toSubscription: 0)
        try await waitUntil { await MainActor.run { model.agentStatus == .idle } }
        let readsWhenIdle = await Self.count("pane.read", in: connection)
        let ticksWhenIdle = await ticks.intervals.count
        try await waitUntil { await ticks.intervals.count >= ticksWhenIdle + 4 }
        chat.cancel()
        await chat.value

        #expect(await ticks.intervals.dropFirst(ticksWhenIdle + 1).allSatisfy { $0 == .seconds(2) })
        #expect(await Self.count("pane.read", in: connection) >= readsWhenIdle + 3)
        #expect(await Self.count("session.snapshot", in: connection) == 3)
    }

    @Test("主機更新來源沒有在訂閱(還沒連上或斷線)時，自己讀快照")
    func readsSnapshotItselfWhenUpdatesAreNotLive() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot("idle"))
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: RecordingSleeper().sleep)
        let model = Self.conversation(connection, updates: updates)

        await model.poll()

        #expect(await Self.count("session.snapshot", in: connection) == 1)
        #expect(model.agentStatus == .idle)
    }
}

/// 輪詢間隔的假 sleep:每次記下要求的間隔，等一下下就結束(讓輪詢一輪輪跑);在場回報的 30 秒一直等到取消。
actor TickSleeper {
    private(set) var intervals: [Duration] = []

    nonisolated var sleep: Sleep {
        { duration in try await self.wait(duration) }
    }

    private func wait(_ duration: Duration) async throws {
        // 30 秒是預覽輪詢、1.5 秒是載入進度指示的延遲(#356):都不是這裡要量的 2 秒畫面輪詢，不記錄也不返回。
        guard duration != .seconds(30), duration != ConversationModel.loadingIndicatorDelay else {
            try await Task.sleep(for: .seconds(3600))
            return
        }
        intervals.append(duration)
        try await Task.sleep(for: .milliseconds(5))
    }
}
