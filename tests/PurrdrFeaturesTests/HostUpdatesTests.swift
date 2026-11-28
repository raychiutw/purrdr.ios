import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機更新來源(#160):每台主機一份事件訂閱與快照;連上即對帳，事件期間只合併成一次快照。
@MainActor
@Suite("主機更新來源", .timeLimit(.minutes(1)))
struct HostUpdatesTests {
    static let snapshot = Fixtures.data("session.snapshot.ndjson")
    static let started = Fixtures.data("events.subscribe.started.ndjson")

    /// 真實主機錄到的狀態事件形狀(#159),只換 pane 與狀態。
    static func statusChanged(_ paneID: String = "w1:pB", status: String = "idle") -> Data {
        Fixtures.modifiedLine("event.pane-agent-status-changed.ndjson") { line in
            var data = line["data"] as? [String: Any] ?? [:]
            data["pane_id"] = paneID
            data["agent_status"] = status
            line["data"] = data
        }
    }

    /// 全主機事件(非狀態事件的名稱用底線，#159)。
    static let workspaceUpdated = Data(#"{"event":"workspace_updated","data":{"type":"workspace_updated","workspace_id":"w1"}}"#.utf8)

    static let eventsLost = Fixtures.modifiedLine("error.pane-not-found.ndjson") {
        $0["error"] = ["code": "events_lost", "message": "event subscription fell behind retained history; resubscribe and resync with session.snapshot"]
    }

    /// 送出的請求的 herdr method,依送出順序。
    static func methods(_ connection: FakeHostConnection) async -> [String] {
        await connection.requests.map { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String ?? ""
        }
    }

    /// 預期 `count` 次快照讀取(回應同一份錄製檔)。
    static func expectSnapshots(_ connection: FakeHostConnection, count: Int) async {
        for _ in 0..<count { await connection.expect(.snapshot, wire: snapshot) }
    }

    static func start(_ connection: FakeHostConnection, sleep: @escaping Sleep = RecordingSleeper { _ in true }.sleep) -> (HostUpdates, Task<Void, Never>) {
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: sleep)
        let task = Task { await updates.run() }
        return (updates, task)
    }

    /// 同步點(取代等實際時間，#324):送一個哨兵事件，等它的快照讀取出現。
    /// 事件與快照讀取是串列處理的，哨兵之前多出來的請求一定排在它前面;所以哨兵的讀取一出現，
    /// 之後對「沒有多餘請求」的斷言就是確定的，不靠等多久。`before` 是送哨兵前已有的請求數。
    static func barrier(_ connection: FakeHostConnection, before: Int, subscription: Int = 0) async throws {
        await connection.expect(.snapshot, wire: snapshot)
        await connection.send(event: workspaceUpdated, toSubscription: subscription)
        try await waitUntil { await connection.requests.count == before + 1 }
    }

    @Test("連上即對帳：讀快照、訂閱，訂閱開始時再讀一次;沒有事件就沒有其他請求")
    func connectingResyncsOnce() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 3)
        let (updates, task) = Self.start(connection)
        defer { task.cancel() }

        try await waitUntil { await connection.requests.count == 3 }
        try await Self.barrier(connection, before: 3)

        #expect(await Self.methods(connection) == ["session.snapshot", "events.subscribe", "session.snapshot", "session.snapshot"])
        #expect(updates.phase == .loaded)
        #expect(updates.snapshot?.agents.count == 3)
    }

    @Test("tab.renamed／workspace.renamed 事件(電腦或另一支手機改名)訂閱在內，到達時重讀快照對帳(#456)")
    func renameEventsReconcile() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 3)
        let (_, task) = Self.start(connection)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        let subscribe = await connection.requests.first { $0.contains("events.subscribe") } ?? ""
        #expect(subscribe.contains("tab.renamed"))
        #expect(subscribe.contains("workspace.renamed"))

        await connection.send(event: Data(#"{"event":"tab_renamed","data":{"type":"tab_renamed","tab_id":"w1:tA","workspace_id":"w1","label":"tests"}}"#.utf8), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        await connection.send(event: Data(#"{"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace_id":"w1","label":"Budget"}}"#.utf8), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 5 }
        #expect(await Self.methods(connection).suffix(2) == ["session.snapshot", "session.snapshot"])
    }

    @Test("事件立刻觸發重讀快照，不等固定延遲;每個事件之間沒有多餘的快照請求")
    func eventTriggersSnapshotWithoutDelay() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 6)
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.send(event: Self.statusChanged(), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        await connection.send(event: Self.statusChanged("w1:pA"), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 5 }
        try await Self.barrier(connection, before: 5)

        #expect(await connection.requests.count == 6)
        #expect(await sleeper.requested.isEmpty, "事件後等了固定延遲")
    }

    @Test("快照讀取期間到達的事件，只合併成讀完後的「再一次」")
    func eventsDuringSnapshotCoalesceIntoOneRead() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 8)
        let (updates, task) = Self.start(connection)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.hold("session.snapshot")
        await connection.send(event: Self.statusChanged(), toSubscription: 0)
        try await waitUntil { await connection.heldCount == 1 }
        let receivedBefore = updates.eventsReceived
        for paneID in ["w1:pA", "w1:p6", "w1:pB"] {
            await connection.send(event: Self.statusChanged(paneID), toSubscription: 0)
        }
        try await waitUntil { await MainActor.run { updates.eventsReceived >= receivedBefore + 3 } }
        #expect(updates.hasQueuedResync)
        await connection.releaseHeld()

        try await waitUntil { await connection.requests.count == 5 }
        try await Self.barrier(connection, before: 5)
        #expect(await Self.methods(connection) == ["session.snapshot", "events.subscribe"] + Array(repeating: "session.snapshot", count: 4))
        #expect(updates.hasQueuedResync == false)
    }

    @Test("workspace.updated 短時間大量到達：讀取期間的全部只觸發一次快照")
    func workspaceUpdatedBurstTriggersOneRead() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 30)
        let (updates, task) = Self.start(connection)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.hold("session.snapshot")
        await connection.send(event: Self.workspaceUpdated, toSubscription: 0)
        try await waitUntil { await connection.heldCount == 1 }
        let receivedBefore = updates.eventsReceived
        for _ in 0..<20 { await connection.send(event: Self.workspaceUpdated, toSubscription: 0) }
        // 送出的事件要全部被處理完才放行:遲到的事件會在放行後多觸發一次讀取(#719)。
        try await waitUntil { await MainActor.run { updates.eventsReceived >= receivedBefore + 20 } }
        await connection.releaseHeld()

        try await waitUntil { await connection.requests.count == 5 }
        try await Self.barrier(connection, before: 5)
        #expect(await connection.requests.count == 6)
    }

    static let layoutUpdated = Data(#"{"event":"layout_updated","data":{"type":"layout_updated","workspace_id":"w1"}}"#.utf8)

    @Test("拖動分隔線的 layout.updated 連發：第一個立刻讀，之後以最小間隔限速，期間的事件不再各讀一次(#587)")
    func layoutUpdatedBurstIsThrottled() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 40)
        let sleeper = RecordingSleeper { _ in false }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.send(event: Self.layoutUpdated, toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        try await waitUntil { await sleeper.requested == [HostUpdates.layoutMinimumInterval] }
        for _ in 0..<30 { await connection.send(event: Self.layoutUpdated, toSubscription: 0) }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await connection.requests.count == 4, "限速期間讀了快照")
    }

    @Test("限速時間到後，期間的版面事件併成一次尾端讀取")
    func layoutBurstTrailingRead() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 10)
        let (updates, task) = Self.start(connection, sleep: RecordingSleeper { _ in true }.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.hold("session.snapshot")
        await connection.send(event: Self.layoutUpdated, toSubscription: 0)
        try await waitUntil { await connection.heldCount == 1 }
        for _ in 0..<5 { await connection.send(event: Self.layoutUpdated, toSubscription: 0) }
        try await waitUntil { await MainActor.run { updates.hasQueuedResync } }
        await connection.releaseHeld()
        try await waitUntil { await connection.requests.count == 5 }
        try await Self.barrier(connection, before: 5)
        #expect(await connection.requests.count == 6, "期間的版面事件應只併成一次尾端讀取")
    }

    @Test("其他事件(狀態改變)不受版面限速影響:不等間隔")
    func nonLayoutEventsAreNotThrottled() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 6)
        let sleeper = RecordingSleeper { _ in false }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }
        await connection.send(event: Self.statusChanged(), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        await connection.send(event: Self.statusChanged("w1:pA"), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 5 }
        #expect(await sleeper.requested.isEmpty)
    }

    @Test("版面限速的等待中,其他事件一到就讀,不被限速拖到間隔結束(#587)")
    func nonLayoutEventInterruptsLayoutThrottle() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 10)
        let sleeper = RecordingSleeper { _ in false }  // 限速的等待永遠不結束
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }
        await connection.send(event: Self.layoutUpdated, toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        try await waitUntil { await sleeper.requested == [HostUpdates.layoutMinimumInterval] }

        await connection.send(event: Self.statusChanged(), toSubscription: 0)

        try await waitUntil { await connection.requests.count == 5 }
    }

    /// 第一次連上之後的(重)訂閱：以手上快照的 pane 訂閱，訂閱開始時讀一次快照對帳，不先讀。
    static func expectResubscription(_ connection: FakeHostConnection) async {
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: Self.snapshot)
    }

    @Test("events_lost:立刻重新訂閱，訂閱開始時讀一次快照對帳，不退避")
    func eventsLostResyncs() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: Self.snapshot)
        await Self.expectResubscription(connection)
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.send(event: Self.eventsLost, toSubscription: 0)

        try await waitUntil { await connection.requests.count == 5 }
        try await Self.barrier(connection, before: 5, subscription: 1)
        #expect(await connection.subscriptionsClosed.first == true)
        #expect(await Self.methods(connection).suffix(4) == ["session.snapshot", "events.subscribe", "session.snapshot", "session.snapshot"])
        #expect(await connection.requests.count == 6, "重新訂閱前多讀了快照")
        #expect(await sleeper.requested.isEmpty)
    }

    @Test("斷線後退避 1 秒再重連，重連只在訂閱開始時讀一次快照對帳")
    func reconnectAfterDropResyncs() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: Self.snapshot)
        await Self.expectResubscription(connection)
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.finish(subscription: 0)

        try await waitUntil { await connection.requests.count == 5 }
        try await Self.barrier(connection, before: 5, subscription: 1)
        #expect(await sleeper.requested == [.seconds(1)])
        #expect(await Self.methods(connection).suffix(4) == ["session.snapshot", "events.subscribe", "session.snapshot", "session.snapshot"])
        #expect(await connection.requests.count == 6, "重連前多讀了快照")
    }

    @Test("重連時手上的 pane 已經關掉(herdr 回 pane_not_found):讀快照換成現有的 pane 再訂閱，不退避")
    func staleOnReconnectReadsSnapshotThenResubscribes() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Fixtures.data("error.pane-not-found.ndjson"))
        let withoutB = Fixtures.modifiedLine("session.snapshot.ndjson") { SnapshotEdit.removeAgent("w1:pB", in: &$0) }
        await connection.expect(.snapshot, wire: withoutB)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: withoutB)
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.finish(subscription: 0)

        try await waitUntil { await connection.requests.count == 7 }
        #expect(await Self.methods(connection).suffix(4) == ["events.subscribe", "session.snapshot", "events.subscribe", "session.snapshot"])
        #expect(!(await connection.requests[5]).contains(#""pane_id":"w1:pB""#))
        #expect(await sleeper.requested == [.seconds(1)])
    }

    @Test("連不上時退避 1 秒起倍增、上限 30 秒")
    func failuresBackOff() async throws {
        let connection = FakeHostConnection()
        // 沒預期訂閱：每次訂閱都失敗。
        await Self.expectSnapshots(connection, count: 7)
        let sleeper = Sleeper(blockAfter: 7)
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }

        try await waitUntil { await sleeper.durations.count == 7 }

        #expect(await sleeper.durations == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }

    @Test("Agent pane 的集合改變時，用新的 pane 集合重新訂閱")
    func paneSetChangeResubscribes() async throws {
        let connection = FakeHostConnection()
        let withoutB = Fixtures.modifiedLine("session.snapshot.ndjson") { SnapshotEdit.removeAgent("w1:pB", in: &$0) }
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: withoutB)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: withoutB)
        let (_, task) = Self.start(connection)
        defer { task.cancel() }

        try await waitUntil { await connection.requests.count == 5 }

        #expect(await connection.subscriptionsClosed == [true, false])
        let resubscribe = await connection.requests[3]
        #expect(resubscribe.contains(#""pane_id":"w1:pA""#))
        #expect(!resubscribe.contains(#""pane_id":"w1:pB""#))
    }

    @Test("iPad 多個畫面同時看：同一台主機只有一份訂閱與快照讀取")
    func viewersShareOneSubscription() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await Self.expectSnapshots(connection, count: 3)
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: RecordingSleeper { _ in true }.sleep)
        let list = AgentListModel(updates: updates)
        let viewers = [Task { await list.liveUpdates.attach() }, Task { await updates.liveUpdates.attach() }]
        defer { viewers.forEach { $0.cancel() } }

        try await waitUntil { await connection.requests.count == 3 }
        try await Self.barrier(connection, before: 3)

        #expect(await Self.methods(connection) == ["session.snapshot", "events.subscribe", "session.snapshot", "session.snapshot"])
        #expect(list.sections.flatMap(\.rows).count == 3)
    }

    @Test("一個 Agent 的變化：先給目前的值，狀態有變才再給")
    func paneChangesFollowSnapshots() async throws {
        let connection = FakeHostConnection()
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expectSubscription(wire: Self.started)
        await connection.expect(.snapshot, wire: Self.snapshot)
        await connection.expect(.snapshot, wire: Self.snapshot)
        // 錄製期間沒有 Agent 變成 blocked:以真實回應為底，只改 w1:pB 的狀態。
        await connection.expect(.snapshot, wire: Fixtures.modifiedLine("session.snapshot.ndjson") {
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        })
        let (updates, task) = Self.start(connection)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }
        var changes = updates.changes(for: "w1:pB").makeAsyncIterator()

        let current = await changes.next()
        #expect(current??.paneID == "w1:pB")
        #expect(current??.status != .blocked)

        // 第一個事件的快照沒變(不給),第二個變成 blocked。
        await connection.send(event: Self.statusChanged(), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        await connection.send(event: Self.statusChanged(status: "blocked"), toSubscription: 0)

        let changed = await changes.next()
        #expect(changed??.status == .blocked)
    }
}
