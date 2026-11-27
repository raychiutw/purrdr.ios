import Foundation
import PurrdrCore
import PurrdrHTTPS
import Synchronization
import Testing

/// HTTPS 主機連線事件(#689、spec #679):撥號、心跳逾時、權杖被拒、連線結束的原因。
/// 經假的主機服務(`answersPings: false`、撤銷權杖、切斷連線)製造情境;前例:`HTTPSLiveUpdatesTests`、`SSHDiagnosticEventsTests`。
@Suite("HTTPS 連線事件")
struct HTTPSDiagnosticEventsTests {
    final class Recorder: Sendable {
        private let stored = Mutex<[HTTPSConnectionEvent]>([])
        var events: [HTTPSConnectionEvent] { stored.withLock { $0 } }
        var sink: HTTPSConnectionDiagnostics { { [self] event in stored.withLock { $0.append(event) } } }
        var hasDropped: Bool { events.contains { if case .dropped = $0 { true } else { false } } }
    }

    private static func connection(
        to service: FakeHostService, token: String = "token-ok", recorder: Recorder,
        heartbeat: HostServiceHeartbeat = .standard, sleep: @escaping Sleep = Sleeping.task
    ) -> HTTPSHostConnection {
        HTTPSHostConnection(
            address: service.address, deviceToken: { token }, appVersion: "9.9.9", heartbeat: heartbeat, sleep: sleep,
            diagnostics: recorder.sink)
    }

    private static func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等不到條件成立")
    }

    @Test("第一個操作撥號成功:記一筆 connected,撥號序號從 1 起", .timeLimit(.minutes(1)))
    func connectedOnFirstOperation() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let recorder = Recorder()
        let connection = Self.connection(to: service, recorder: recorder)

        _ = try await HerdrClient(connection: connection).snapshot()

        #expect(recorder.events == [.connected(dial: 1)])
        await connection.disconnect()
    }

    @Test("主機不回 pong:中斷原因是心跳逾時", .timeLimit(.minutes(1)))
    func heartbeatTimeoutIsReported() async throws {
        let service = try await FakeHostService.start(.init(answersPings: false))
        defer { Task { await service.stop() } }
        let recorder = Recorder()
        let gate = HTTPSLiveUpdatesTests.Gate()
        let connection = Self.connection(to: service, recorder: recorder, heartbeat: HTTPSLiveUpdatesTests.gatedHeartbeat, sleep: gate.sleep)
        _ = try await HerdrClient(connection: connection).subscribe([])

        gate.open()
        try await Self.waitUntil { recorder.hasDropped }

        guard case .dropped(let dial, let reason, _)? = recorder.events.last else { Issue.record("沒有中斷事件"); return }
        #expect(dial == 1)
        #expect(reason == .heartbeatTimeout)
    }

    @Test("連線中權杖被撤銷:中斷原因是權杖被拒", .timeLimit(.minutes(1)))
    func tokenRevokedWhileConnected() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let recorder = Recorder()
        let connection = Self.connection(to: service, recorder: recorder)
        let client = HerdrClient(connection: connection)
        _ = try await client.snapshot()

        service.revoke("token-ok")
        _ = try? await client.snapshot()
        try await Self.waitUntil { recorder.hasDropped }

        guard case .dropped(_, let reason, _)? = recorder.events.last else { Issue.record("沒有中斷事件"); return }
        #expect(reason == .tokenRejected)
    }

    @Test("一開始就被拒絕的權杖:撥號失敗只記錯誤種類", .timeLimit(.minutes(1)))
    func rejectedTokenFailsTheDial() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let recorder = Recorder()
        let connection = Self.connection(to: service, token: "token-bad", recorder: recorder)

        _ = try? await HerdrClient(connection: connection).snapshot()

        let failed = recorder.events.compactMap { event -> (Int, String)? in
            if case .dialFailed(let dial, let error, _) = event { (dial, error) } else { nil }
        }
        #expect(failed.count == 1)
        #expect(failed.first?.0 == 1)
        #expect(failed.first?.1 == "deviceTokenInvalid")
    }

    @Test("網路被切斷(沒有 close frame):記為中斷,壽命從撥號成功起算", .timeLimit(.minutes(1)))
    func connectionCutIsReported() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let recorder = Recorder()
        let connection = Self.connection(to: service, recorder: recorder)
        _ = try await HerdrClient(connection: connection).snapshot()

        await service.dropConnections()
        try await Self.waitUntil { recorder.hasDropped }

        guard case .dropped(let dial, let reason, let lifetime)? = recorder.events.last else { Issue.record("沒有中斷事件"); return }
        #expect(dial == 1)
        #expect(reason != .disconnectRequested)
        #expect(lifetime >= .zero)
    }

    @Test("app 要求斷線:原因是 disconnectRequested;之後重撥序號加一", .timeLimit(.minutes(1)))
    func disconnectRequestedThenRedial() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let recorder = Recorder()
        let connection = Self.connection(to: service, recorder: recorder)
        let client = HerdrClient(connection: connection)
        _ = try await client.snapshot()
        await connection.disconnect()
        _ = try await client.snapshot()

        let codes = recorder.events.map { event -> String in
            switch event {
            case .connected(let dial): "connected \(dial)"
            case .dialFailed(let dial, _, _): "failed \(dial)"
            case .dropped(let dial, let reason, _): "dropped \(dial) \(reason)"
            }
        }
        #expect(codes == ["connected 1", "dropped 1 disconnectRequested", "connected 2"])
        await connection.disconnect()
    }

    @Test("關鍵請求記耗時 https.request <method>;快照輪詢不記;沒接出口不影響", .timeLimit(.minutes(1)))
    func timesKeyRequestsOnly() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let timings = Mutex<[OperationTiming]>([])
        let connection = Self.connection(to: service, recorder: Recorder())
        let client = HerdrClient(connection: connection)

        _ = try await client.prompt(target: "w1:p6", text: "before", wait: nil)
        connection.attachTimings { timing in timings.withLock { $0.append(timing) } }
        _ = try await client.snapshot()
        _ = try await client.prompt(target: "w1:p6", text: "hi", wait: nil)

        let recorded = timings.withLock { $0 }
        #expect(recorded.map(\.name) == ["https.request agent.prompt"])
        #expect(recorded.first?.failed == false)
        await connection.disconnect()
    }
}
