import Foundation
import Synchronization
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的即時更新(#58):主機服務推送 Agent 事件、心跳逾時斷線。
/// 經真正的 WebSocket(URLSession)連假的主機服務，從 `HerdrClient` 這一端驗證。
@Suite("HTTPS 即時更新")
struct HTTPSLiveUpdatesTests {
    static func connection(
        to service: FakeHostService, heartbeat: HostServiceHeartbeat = .standard, sleep: @escaping Sleep = Sleeping.task
    ) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9", heartbeat: heartbeat, sleep: sleep)
    }

    /// 心跳逾時的測試不靠實際時間(#324):間隔與逾時的等待都卡在閘門上，連線與訂閱完成後才由測試打開，
    /// 打開後等待立刻結束，所以 ping 一送出沒有 pong 就逾時。數值只是讓「誰在等」看得出來，永遠不會真的等。
    static let gatedHeartbeat = HostServiceHeartbeat(interval: .seconds(1), timeout: .seconds(1))

    /// 超過這個長度的等待代表「一般間隔」,閘門打開也不結束(只有被取消才返回)，用來證明快速偵測有改用短間隔。
    static let neverElapses = Duration.seconds(1000)

    final class Gate: Sendable {
        private let isOpen = Mutex(false)
        private let signal = WakeSignal()

        /// 閘門打開前一直等(取消時丟 `CancellationError`);打開後立刻返回。
        var sleep: Sleep {
            { [self] duration in
                if duration > HTTPSLiveUpdatesTests.neverElapses {
                    while true { try await signal.wait(atMost: nil) }
                }
                while !isOpen.withLock({ $0 }) { try await signal.wait(atMost: nil) }
            }
        }

        func open() {
            isOpen.withLock { $0 = true }
            signal.wake()
        }
    }

    @Test("主機服務推送的事件轉成 herdr 事件;訂閱內容原樣送到主機服務")
    func pushedEventsReachHerdrClient() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))

        let events = try await client.subscribe([.agentStatusChanged(paneID: "w1:p6"), .init(.workspaceCreated)])
        service.pushEvent("pane_agent_status_changed", paneID: "w1:p6")
        service.pushEvent("workspace_created")
        let read = await Self.read(events, count: 3)

        #expect(read == StreamRead(
            events: [.subscriptionStarted, .event(name: "pane_agent_status_changed", paneID: "w1:p6"), .event(name: "workspace_created", paneID: nil)],
            ending: .stillOpen))
        let subscribe = try #require(service.log.messages.compactMap(Self.object).first { $0["type"] as? String == "events.subscribe" })
        let subscriptions = subscribe["subscriptions"] as? [[String: String]]
        #expect(subscriptions == [["event": "pane.agent_status_changed", "pane_id": "w1:p6"], ["event": "workspace.created"]])
    }

    @Test("herdr 的 events_lost:串流以 herdr 錯誤結束(上層重新訂閱並對帳)")
    func eventsLostEndsStream() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let events = try await HerdrClient(connection: Self.connection(to: service)).subscribe([])
        try await waitUntil { service.openStreams.count == 1 }

        service.endStreams(code: "herdr_error", message: "event history overflowed", herdrCode: "events_lost")
        let read = await Self.read(events)

        let lost = HerdrError.herdr(code: "events_lost", message: "event history overflowed")
        #expect(read == StreamRead(events: [.subscriptionStarted], ending: .failed(String(describing: lost))))
    }

    @Test("呼叫端不再讀：通知主機服務關掉那條串流，連線保留給其他操作")
    func cancellingClosesStreamOnHostService() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        let reader = Task {
            for try await _ in try await client.subscribe([]) {}
        }
        defer { reader.cancel() }
        try await waitUntil { service.openStreams.count == 1 }

        reader.cancel()

        try await waitUntil { service.openStreams.isEmpty }
        _ = try await client.snapshot()
        #expect(service.log.connections == 1)
    }

    @Test("訂閱結果還沒回來就不讀了：主機可能已開了串流，也通知它關掉")
    func cancellingBeforeAcknowledgementClosesStreamOnHostService() async throws {
        let service = try await FakeHostService.start(.init(subscribeReply: .acceptWithoutReply))
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))
        let reader = Task {
            for try await _ in try await client.subscribe([]) {}
        }
        defer { reader.cancel() }
        try await waitUntil { service.openStreams.count == 1 }

        reader.cancel()

        try await waitUntil { service.openStreams.isEmpty }
    }

    @Test("herdr 沒有事件訂閱能力：訂閱以 herdrCapabilityMissing 失敗，Agent 列表照常可讀")
    func capabilityMissingOnlyDisablesEvents() async throws {
        let service = try await FakeHostService.start(.init(subscribeReply: .error(code: "herdr_capability_missing")))
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(to: service))

        await #expect(throws: HostServiceError.herdrCapabilityMissing) { _ = try await client.subscribe([]) }
        #expect(try await client.snapshot().agents.count == 2)
    }

    @Test("心跳：主機服務有回 pong 就保持同一條連線")
    func heartbeatKeepsHealthyConnection() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        // pong 逾時放寬，CI 忙的時候也不會誤判成斷線。
        let heartbeat = HostServiceHeartbeat(interval: .milliseconds(100), timeout: .seconds(5))
        let client = HerdrClient(connection: Self.connection(to: service, heartbeat: heartbeat))
        _ = try await client.snapshot()

        try await waitUntil { service.log.pings >= 3 }
        _ = try await client.snapshot()

        #expect(service.log.connections == 1)
    }

    @Test("心跳逾時(主機服務不回 pong):連線以 connectionLost 結束，事件串流跟著結束")
    func heartbeatTimeoutDropsConnection() async throws {
        let service = try await FakeHostService.start(.init(answersPings: false))
        defer { Task { await service.stop() } }
        let gate = Gate()
        let events = try await HerdrClient(connection: Self.connection(to: service, heartbeat: Self.gatedHeartbeat, sleep: gate.sleep)).subscribe([])

        gate.open()
        let read = await Self.read(events)

        #expect(read == StreamRead(events: [.subscriptionStarted], ending: .failed(String(describing: HostServiceError.connectionLost))))
    }

    @Test("快速偵測斷線(聊天畫面可見):心跳立刻改用短間隔，不等一般間隔")
    func quickDetectionUsesShortHeartbeat() async throws {
        let service = try await FakeHostService.start(.init(answersPings: false))
        defer { Task { await service.stop() } }
        let gate = Gate()
        let connection = HTTPSHostConnection(
            address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9",
            heartbeat: HostServiceHeartbeat(interval: .seconds(3600), timeout: .seconds(1)), quickHeartbeat: Self.gatedHeartbeat,
            sleep: gate.sleep)
        let events = try await HerdrClient(connection: connection).subscribe([])

        gate.open()
        await connection.beginQuickDisconnectDetection()
        let read = await Self.read(events)

        #expect(read == StreamRead(events: [.subscriptionStarted], ending: .failed(String(describing: HostServiceError.connectionLost))))
    }

    @Test("心跳的快速偵測：最壞 15 秒(間隔加逾時)")
    func quickHeartbeatWorstCase() {
        #expect(HostServiceHeartbeat.quick.interval + HostServiceHeartbeat.quick.timeout <= .seconds(15))
    }

    // MARK: - 輔助

    private static func object(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    struct StreamRead: Equatable {
        var events: [HerdrEvent]
        var ending: Ending

        enum Ending: Equatable {
            /// 讀到 `count` 個就停了，串流還開著。
            case stillOpen
            case finished
            /// 以這個錯誤結束(`String(describing:)`)。
            case failed(String)
            /// 期限到還沒讀完。
            case timedOut
        }
    }

    /// 讀串流到 `count` 個或結束為止;最多等 `limit`,不讓測試卡住。
    private static func read(
        _ events: AsyncThrowingStream<HerdrEvent, any Error>, count: Int? = nil, within limit: Duration = .seconds(5)
    ) async -> StreamRead {
        await withTaskGroup(of: StreamRead.self) { group in
            group.addTask {
                var received: [HerdrEvent] = []
                do {
                    for try await event in events {
                        received.append(event)
                        if received.count == count { return StreamRead(events: received, ending: .stillOpen) }
                    }
                    return StreamRead(events: received, ending: .finished)
                } catch {
                    return StreamRead(events: received, ending: .failed(String(describing: error)))
                }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return StreamRead(events: [], ending: .timedOut)
            }
            let first = await group.next() ?? StreamRead(events: [], ending: .timedOut)
            group.cancelAll()
            return first
        }
    }
}
