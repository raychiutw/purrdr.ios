import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

@Suite("herdr 事件訂閱(events.subscribe)")
struct HerdrEventsTests {
    static let bridge = HerdrCommand.bridge()

    /// 真實主機錄到的狀態事件形狀(#159):事件名是 `pane.agent_status_changed`(點),`data` 沒有 `type`。
    static let statusChangedLine = Fixtures.data("event.pane-agent-status-changed.ndjson")

    @Test("訂閱：對 bridge 送一行訂閱請求、不送 EOF;先收到 subscription_started,之後是事件")
    func subscribeSendsRequestAndYieldsEvents() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))

        let events = try await HerdrClient(channel: host).subscribe([
            .agentStatusChanged(paneID: "w1:p6"),
            .init(.workspaceCreated),
        ])
        var iterator = events.makeAsyncIterator()
        let first = try await iterator.next()
        await host.send(stdout: Self.statusChangedLine, toExecution: 0)
        let second = try await iterator.next()

        #expect(first == .subscriptionStarted)
        #expect(second == .event(name: "pane.agent_status_changed", paneID: "w1:pB"))
        let execution = try #require(await host.executions.first)
        #expect(execution.stdinText == #"{"id":"purrdr:events.subscribe","method":"events.subscribe","params":{"subscriptions":[{"pane_id":"w1:p6","type":"pane.agent_status_changed"},{"type":"workspace.created"}]}}"# + "\n")
        #expect(execution.closedStdin == false)
        #expect(execution.closed == false)
    }

    @Test("訂閱：不再讀事件時由 app 關閉通道")
    func subscribeClosesChannelWhenConsumerStops() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))

        do {
            let events = try await HerdrClient(channel: host).subscribe([.init(.workspaceCreated)])
            for try await event in events where event == .subscriptionStarted { break }
        }

        try await waitUntil { await host.executions.first?.closed == true }
        #expect(await host.executions.first?.closedStdin == false)
    }

    @Test("訂閱被拒(例如 pane 已不存在)時，以 herdr 的錯誤碼失敗")
    func rejectedSubscriptionFails() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.pane-not-found.ndjson"))

        let events = try await HerdrClient(channel: host).subscribe([.agentStatusChanged(paneID: "w9:pZ")])

        await #expect(throws: HerdrError.herdr(code: "pane_not_found", message: "pane w9:pZ not found")) {
            for try await _ in events {}
        }
    }

    /// `events_lost` 錄不到(要讓伺服器的事件歷史溢出);錯誤碼與訊息取自 herdr 0.9.5 執行檔，形狀同錄製的錯誤 envelope。
    @Test("訂閱中收到 events_lost 時以該錯誤結束，讓呼叫端重新訂閱並重讀")
    func eventsLostEndsStream() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("events.subscribe.started.ndjson", keepsOpen: true))
        let eventsLost = Fixtures.modifiedLine("error.pane-not-found.ndjson") {
            $0["error"] = ["code": "events_lost", "message": "event subscription fell behind retained history; resubscribe and resync with session.snapshot"]
        }

        let events = try await HerdrClient(channel: host).subscribe([.init(.workspaceCreated)])
        var received: [HerdrEvent] = []
        await host.send(stdout: eventsLost, toExecution: 0)

        await #expect(throws: HerdrError.herdr(code: "events_lost", message: "event subscription fell behind retained history; resubscribe and resync with session.snapshot")) {
            for try await event in events { received.append(event) }
        }
        #expect(received == [.subscriptionStarted])
    }

    @Test("bridge 沒有任何回應就結束時，帶上 exit code 與 stderr 失敗")
    func streamEndingWithoutResponseFails() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: FakeReply(stderr: Data("failed to connect to remote Herdr API socket".utf8), exitCode: 1))

        let events = try await HerdrClient(channel: host).subscribe([.init(.workspaceCreated)])

        await #expect(throws: HerdrError.noResponse(exitCode: 1, stderr: "failed to connect to remote Herdr API socket")) {
            for try await _ in events {}
        }
    }
}

/// 等到條件成立(上限 `asyncWaitLimit`;條件一成立就返回)。給背景進行中的串流與 task 用。
func waitUntil(_ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + asyncWaitLimit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等不到條件成立", sourceLocation: sourceLocation)
    throw CancellationError()
}
