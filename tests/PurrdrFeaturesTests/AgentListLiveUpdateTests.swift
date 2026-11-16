import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 即時更新(行為規格 §3.7):事件只當重讀的觸發;訂閱開始與 `events_lost` 時重讀 snapshot 對帳。
@MainActor
@Suite("Agent 列表即時更新")
struct AgentListLiveUpdateTests {
    static let bridge = HerdrCommand.bridge()
    static let started = FakeReply.recorded("events.subscribe.started.ndjson", keepsOpen: true)
    static let snapshot = FakeReply.recorded("session.snapshot.ndjson")

    /// 依 herdr 0.9.5 schema 的事件行(錄製期間主機上沒有狀態改變);只當觸發，內容不影響結果。
    static let statusChanged = Data(
        #"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w1:pB","workspace_id":"w1","agent":"claude","agent_status":"idle"}}"#.utf8
    ) + [0x0A]

    static func subscribeRequest(panes: [String]) -> String {
        let perPane = panes.map { #"{"pane_id":"\#($0)","type":"pane.agent_status_changed"}"# }
        let hostWide = ["workspace.created", "workspace.closed", "workspace.renamed", "workspace.updated", "pane.agent_detected", "pane.exited"]
            .map { #"{"type":"\#($0)"}"# }
        return #"{"id":"purrdr:events.subscribe","method":"events.subscribe","params":{"subscriptions":["# +
            (perPane + hostWide).joined(separator: ",") + "]}}\n"
    }

    /// 開始即時更新，回傳 model 與執行中的 task(測試結尾取消)。
    static func start(_ host: FakeHost, sleeper: Sleeper) -> (AgentListModel, Task<Void, Never>) {
        let model = AgentListModel(client: HerdrClient(channel: host), sleep: sleeper.sleep)
        let task = Task { await model.run() }
        return (model, task)
    }

    @Test("先讀 snapshot,再訂閱每個 Agent pane 的狀態與全主機事件;訂閱開始時重讀對帳")
    func subscribesAfterSnapshotAndResyncsOnStart() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: Self.snapshot)
        let (model, task) = Self.start(host, sleeper: Sleeper())
        defer { task.cancel() }

        try await waitUntil { await host.consumedAll(executions: 3) }
        try await waitUntil { await host.executions.last?.closed == true }

        let executions = await host.executions
        #expect(executions[0].stdinText.contains(#""method":"session.snapshot""#))
        #expect(executions[1].stdinText == Self.subscribeRequest(panes: ["w1:p6", "w1:pA", "w1:pB"]))
        #expect(executions[1].closedStdin == false)
        #expect(executions[1].closed == false)
        #expect(executions[2].stdinText.contains(#""method":"session.snapshot""#))
        #expect(model.phase == .loaded)
    }

    @Test("收到事件就重讀 snapshot,列表反映主機的新狀態")
    func eventTriggersRereadAndUpdatesRows() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        })
        let (model, task) = Self.start(host, sleeper: Sleeper())
        defer { task.cancel() }
        try await waitUntil { await host.executions.count == 3 }
        try await waitUntil { await host.executions[2].closed }

        await host.send(stdout: Self.statusChanged, toExecution: 1)

        try await waitUntil { await MainActor.run { model.sections.first?.group == .needsYou } }
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:pB"])
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("events_lost:關掉舊訂閱、立刻重新訂閱並重讀，不等退避")
    func eventsLostResubscribesAndRereads() async throws {
        let host = FakeHost()
        for _ in 0..<2 {
            await host.expect(Self.bridge, reply: Self.snapshot)
            await host.expect(Self.bridge, reply: Self.started)
            await host.expect(Self.bridge, reply: Self.snapshot)
        }
        let sleeper = Sleeper()
        let (_, task) = Self.start(host, sleeper: sleeper)
        defer { task.cancel() }
        try await waitUntil { await host.executions.count == 3 }

        await host.send(stdout: Fixtures.modifiedLine("error.pane-not-found.ndjson") {
            $0["error"] = ["code": "events_lost", "message": "event subscription fell behind retained history; resubscribe and resync with session.snapshot"]
        }, toExecution: 1)

        try await waitUntil { await host.consumedAll(executions: 6) }
        #expect(await host.executions[1].closed)
        #expect(await host.executions[4].stdinText.contains("events.subscribe"))
        #expect(await sleeper.durations.isEmpty)
    }

    @Test("Agent pane 的集合改變時，關掉舊訂閱、用新的 pane 集合重新訂閱")
    func paneSetChangeResubscribes() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.removeAgent("w1:pB", in: &$0) })
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.removeAgent("w1:pB", in: &$0) })
        let (model, task) = Self.start(host, sleeper: Sleeper())
        defer { task.cancel() }

        try await waitUntil { await host.consumedAll(executions: 5) }

        #expect(await host.executions[1].closed)
        #expect(await host.executions[3].stdinText == Self.subscribeRequest(panes: ["w1:p6", "w1:pA"]))
        #expect(await host.executions[3].closed == false)
        try await waitUntil { await MainActor.run { model.sections.flatMap(\.rows).count == 2 } }
    }

    @Test("Agent pane 只是順序不同時不重新訂閱")
    func paneReorderKeepsSubscription() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { response in
            var result = response["result"] as? [String: Any] ?? [:]
            var snapshot = result["snapshot"] as? [String: Any] ?? [:]
            snapshot["agents"] = Array(((snapshot["agents"] as? [Any]) ?? []).reversed())
            result["snapshot"] = snapshot
            response["result"] = result
        })
        await host.expect(Self.bridge, reply: Self.snapshot)
        let (_, task) = Self.start(host, sleeper: Sleeper())
        defer { task.cancel() }

        try await waitUntil { await host.executions.count >= 3 }
        try await waitUntil { await host.executions[2].closed }
        // 不用固定等待：在原訂閱上再送一個事件當哨兵。事件依序處理，它觸發的重讀(第 4 次執行)出現時，
        // 順序不同的那次重讀一定已經比對完 pane 集合;若誤判成改變，第 4 次執行會是重新訂閱。
        await host.send(stdout: Self.statusChanged, toExecution: 1)
        try await waitUntil { await host.executions.count >= 4 }

        #expect(await host.executions.count == 4)
        #expect(await host.executions[3].stdinText.contains(#""method":"session.snapshot""#), "pane 只是順序不同卻重新訂閱")
        #expect(await host.executions[1].closed == false)
    }

    @Test("訂閱在開始前就結束算失敗：退避 1 秒起倍增、上限 30 秒")
    func failedSubscriptionBacksOff() async throws {
        let host = FakeHost()
        for _ in 0..<7 {
            await host.expect(Self.bridge, reply: Self.snapshot)
            await host.expect(Self.bridge, reply: FakeReply(exitCode: 1, trigger: .afterStdinLine))
        }
        let sleeper = Sleeper(blockAfter: 7)
        let (_, task) = Self.start(host, sleeper: sleeper)
        defer { task.cancel() }

        try await waitUntil { await sleeper.durations.count == 7 }

        #expect(await sleeper.durations == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }

    @Test("訂閱開始後才斷線：退避從 1 秒重新算")
    func backoffResetsAfterSubscriptionStarted() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 1, trigger: .afterStdinLine))
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: Self.snapshot)
        let sleeper = Sleeper(blockAfter: 2)
        let (_, task) = Self.start(host, sleeper: sleeper)
        defer { task.cancel() }
        try await waitUntil { await host.executions.count == 5 }
        try await waitUntil { await host.executions[4].closed }

        await host.finish(execution: 3)

        try await waitUntil { await sleeper.durations.count == 2 }
        #expect(await sleeper.durations == [.seconds(1), .seconds(1)])
    }

    @Test("讀取失敗時保留上一次的列，並顯示錯誤")
    func keepsRowsWhenRereadFails() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: .recorded("error.invalid-request.ndjson"))
        let sleeper = Sleeper(blockAfter: 1)
        let (model, task) = Self.start(host, sleeper: sleeper)
        defer { task.cancel() }

        try await waitUntil { await sleeper.durations.count == 1 }

        #expect(model.phase == .failed("invalid request: key must be a string at line 1 column 56"))
        #expect(model.sections.flatMap(\.rows).count == 3)
        #expect(await host.executions[1].closed)
    }

    @Test("取消 Tailscale 重新驗證後不自動重試(不會一直跳出驗證);按「再試一次」才重新連線並恢復即時更新")
    func cancelledTailscaleCheckWaitsForRetry() async throws {
        let host = FakeHost()
        await host.failConnection(with: SSHConnectionError.tailscaleCheckCancelled)
        let sleeper = Sleeper()
        let (model, task) = Self.start(host, sleeper: sleeper)
        defer { task.cancel() }

        try await waitUntil { await MainActor.run { model.phase != .loading } }
        // 停下來等「再試一次」(不用固定等待;自動重試的話永遠不會進入這個狀態)。
        try await waitUntil { await MainActor.run { model.isWaitingForRetry } }
        #expect(await sleeper.durations.isEmpty, "取消驗證後還在退避重試")

        await host.restoreConnection()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: Self.snapshot)
        await model.load()

        try await waitUntil { await host.consumedAll(executions: 3) }
        #expect(model.phase == .loaded)
        #expect(await host.executions[1].closed == false, "恢復後沒有回到即時更新")
    }

    @Test("停止即時更新(離開畫面或進背景)時關閉訂閱通道")
    func cancellingClosesSubscription() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot)
        await host.expect(Self.bridge, reply: Self.started)
        await host.expect(Self.bridge, reply: Self.snapshot)
        let (_, task) = Self.start(host, sleeper: Sleeper())
        try await waitUntil { await host.executions.count == 3 }

        task.cancel()
        await task.value

        try await waitUntil { await host.executions[1].closed }
        #expect(await host.executions.count == 3)
    }
}

/// 假的 sleep:記錄每次要求的時間。前 `blockAfter - 1` 次立即返回，之後一直等到被取消(讓迴圈停住好斷言)。
/// 250ms 的事件去抖不記錄。
actor Sleeper {
    private(set) var durations: [Duration] = []
    private let blockAfter: Int

    init(blockAfter: Int = .max) {
        self.blockAfter = blockAfter
    }

    nonisolated var sleep: @Sendable (Duration) async throws -> Void {
        { duration in try await self.sleep(for: duration) }
    }

    private func sleep(for duration: Duration) async throws {
        guard duration >= .seconds(1) else { return }
        durations.append(duration)
        if durations.count >= blockAfter {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

extension FakeHost {
    /// 預期的指令都執行過，而且剛好執行了 `count` 次。
    func consumedAll(executions count: Int) -> Bool {
        unmetExpectations.isEmpty && executions.count == count
    }
}

/// 等到條件成立(上限 `asyncWaitLimit`;條件一成立就返回)。
func waitUntil(_ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + asyncWaitLimit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等不到條件成立", sourceLocation: sourceLocation)
    throw CancellationError()
}
