import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機更新來源(#160):每台主機一份事件訂閱與快照;連上即對帳，事件期間只合併成一次快照。
@MainActor
@Suite("主機更新來源")
struct HostUpdatesTests {
    static let snapshot = Fixtures.data("session.snapshot.ndjson")
    static let started = Fixtures.data("events.subscribe.started.ndjson")

    static func statusChanged(_ paneID: String = "w1:pB", status: String = "idle") -> Data {
        Data(
            #"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"\#(paneID)","workspace_id":"w1","agent":"claude","agent_status":"\#(status)"}}"#.utf8)
    }

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
        for _ in 0..<count { await connection.expect("session.snapshot", reply: snapshot) }
    }

    static func start(_ connection: FakeHostConnection, sleep: @escaping Sleep = RecordingSleeper { _ in true }.sleep) -> (HostUpdates, Task<Void, Never>) {
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: sleep)
        let task = Task { await updates.run() }
        return (updates, task)
    }

    /// 等一段實際時間，讓不該發生的請求有機會出現。
    static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test("連上即對帳：讀快照、訂閱，訂閱開始時再讀一次;沒有事件就沒有其他請求")
    func connectingResyncsOnce() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await Self.expectSnapshots(connection, count: 3)
        let (updates, task) = Self.start(connection)
        defer { task.cancel() }

        try await waitUntil { await connection.requests.count == 3 }
        try await Self.settle()

        #expect(await Self.methods(connection) == ["session.snapshot", "events.subscribe", "session.snapshot"])
        #expect(updates.phase == .loaded)
        #expect(updates.snapshot?.agents.count == 3)
    }

    @Test("事件立刻觸發重讀快照，不等固定延遲;每個事件之間沒有多餘的快照請求")
    func eventTriggersSnapshotWithoutDelay() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await Self.expectSnapshots(connection, count: 6)
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.send(event: Self.statusChanged(), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 4 }
        await connection.send(event: Self.statusChanged("w1:pA"), toSubscription: 0)
        try await waitUntil { await connection.requests.count == 5 }
        try await Self.settle()

        #expect(await connection.requests.count == 5)
        #expect(await sleeper.requested.isEmpty, "事件後等了固定延遲")
    }

    @Test("快照讀取期間到達的事件，只合併成讀完後的「再一次」")
    func eventsDuringSnapshotCoalesceIntoOneRead() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await Self.expectSnapshots(connection, count: 8)
        let (updates, task) = Self.start(connection)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.hold("session.snapshot")
        await connection.send(event: Self.statusChanged(), toSubscription: 0)
        try await waitUntil { await connection.heldCount == 1 }
        for paneID in ["w1:pA", "w1:p6", "w1:pB"] {
            await connection.send(event: Self.statusChanged(paneID), toSubscription: 0)
        }
        try await waitUntil { await MainActor.run { updates.hasQueuedResync } }
        await connection.releaseHeld()

        try await waitUntil { await connection.requests.count == 5 }
        try await Self.settle()
        #expect(await Self.methods(connection) == ["session.snapshot", "events.subscribe"] + Array(repeating: "session.snapshot", count: 3))
        #expect(updates.hasQueuedResync == false)
    }

    @Test("events_lost:立刻重新訂閱並重讀快照對帳，不退避")
    func eventsLostResyncs() async throws {
        let connection = FakeHostConnection()
        for _ in 0..<2 {
            await connection.expect("session.snapshot", reply: Self.snapshot)
            await connection.expect("events.subscribe", reply: Self.started)
            await connection.expect("session.snapshot", reply: Self.snapshot)
        }
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.send(event: Self.eventsLost, toSubscription: 0)

        try await waitUntil { await connection.requests.count == 6 }
        #expect(await connection.subscriptionsClosed.first == true)
        #expect(await Self.methods(connection).suffix(3) == ["session.snapshot", "events.subscribe", "session.snapshot"])
        #expect(await sleeper.requested.isEmpty)
    }

    @Test("斷線後退避 1 秒再重連，重連後讀快照對帳")
    func reconnectAfterDropResyncs() async throws {
        let connection = FakeHostConnection()
        for _ in 0..<2 {
            await connection.expect("session.snapshot", reply: Self.snapshot)
            await connection.expect("events.subscribe", reply: Self.started)
            await connection.expect("session.snapshot", reply: Self.snapshot)
        }
        let sleeper = RecordingSleeper { _ in true }
        let (_, task) = Self.start(connection, sleep: sleeper.sleep)
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }

        await connection.finish(subscription: 0)

        try await waitUntil { await connection.requests.count == 6 }
        #expect(await sleeper.requested == [.seconds(1)])
        #expect(await Self.methods(connection).suffix(3) == ["session.snapshot", "events.subscribe", "session.snapshot"])
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
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await connection.expect("session.snapshot", reply: withoutB)
        await connection.expect("events.subscribe", reply: Self.started)
        await connection.expect("session.snapshot", reply: withoutB)
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
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await Self.expectSnapshots(connection, count: 3)
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: RecordingSleeper { _ in true }.sleep)
        let list = AgentListModel(updates: updates)
        let viewers = [Task { await list.liveUpdates.attach() }, Task { await updates.liveUpdates.attach() }]
        defer { viewers.forEach { $0.cancel() } }

        try await waitUntil { await connection.requests.count == 3 }
        try await Self.settle()

        #expect(await Self.methods(connection) == ["session.snapshot", "events.subscribe", "session.snapshot"])
        #expect(list.sections.flatMap(\.rows).count == 3)
    }

    @Test("一個 Agent 的變化：先給目前的值，狀態有變才再給")
    func paneChangesFollowSnapshots() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("session.snapshot", reply: Self.snapshot)
        // 錄製期間沒有 Agent 變成 blocked:以真實回應為底，只改 w1:pB 的狀態。
        await connection.expect("session.snapshot", reply: Fixtures.modifiedLine("session.snapshot.ndjson") {
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
