import Foundation
import NIOCore
import NIOPosix
import PurrdrCore
import PurrdrSSH
import Synchronization
import Testing

/// 連線生命週期的診斷事件(#133):實機斷線時，從 Console 看得出連線為什麼被丟棄、活了多久。
/// 對本機的測試用 SSH 伺服器跑，期限以手動時鐘推進。
@Suite("SSH 連線診斷")
struct SSHConnectionDiagnosticsTests {
    /// 收集診斷事件(事件從 event loop 或 actor 送來)。
    final class Events: Sendable {
        private let events = Mutex<[SSHConnectionEvent]>([])
        var observer: SSHConnectionDiagnostics { { event in self.events.withLock { $0.append(event) } } }
        var all: [SSHConnectionEvent] { events.withLock { $0 } }
        var dropReasons: [SSHDropReason] {
            all.compactMap { if case .dropped(_, let reason, _) = $0 { reason } else { nil } }
        }
    }

    @Test("撥號成功記錄 connected(撥號序號)", .timeLimit(.minutes(1)))
    func recordsConnected() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "ok") }
        defer { server.stop() }
        let events = Events()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, diagnostics: events.observer)

        _ = try await collect(channel.execute("first"))

        #expect(events.all == [.connected(dial: 1)])
        await channel.disconnect()
    }

    @Test("主機不回 keepalive:丟棄原因是 keepalive 逾時", .timeLimit(.minutes(1)))
    func keepaliveTimeoutIsRecorded() async throws {
        let server = try await TestSSHServer.start(keepalive: .ignore) { _ in .reply(stdout: "ok") }
        defer { server.stop() }
        let clock = ManualSSHClock()
        let events = Events()
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            timeouts: SSHTimeouts(keepaliveInterval: .milliseconds(100), keepaliveReply: .milliseconds(200)), scheduler: clock,
            diagnostics: events.observer)

        _ = try await collect(channel.execute("first"))
        // 第一個間隔有 first 的回應(跳過),下一個安靜的間隔才送。
        await clock.advance(by: .milliseconds(100))
        await clock.advance(by: .milliseconds(100))
        try await eventually { server.snapshot.keepalives == 1 }
        await clock.advance(by: .milliseconds(200))
        try await eventually { !events.dropReasons.isEmpty }

        #expect(events.dropReasons == [.keepaliveTimeout])
        await channel.disconnect()
    }

    @Test("開 channel 逾時:整條連線丟棄，原因是開 channel 逾時", .timeLimit(.minutes(1)))
    func channelOpenTimeoutIsRecorded() async throws {
        let server = try await TestSSHServer.start { command in command == "stuck" ? .neverReply : .reply(stdout: "ok") }
        defer { server.stop() }
        let clock = ManualSSHClock()
        let events = Events()
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            timeouts: SSHTimeouts(channelOpen: .seconds(20), keepaliveInterval: nil), scheduler: clock, diagnostics: events.observer)

        _ = try await collect(channel.execute("first"))
        let stuck = Task { _ = try await channel.execute("stuck") }
        try await eventually { server.snapshot.commands == ["first", "stuck"] }
        await clock.advance(by: .seconds(20))
        await #expect(throws: SSHConnectionError.timedOut) { try await stuck.value }
        try await eventually { !events.dropReasons.isEmpty }

        #expect(events.dropReasons == [.channelOpenTimeout])
        await channel.disconnect()
    }

    @Test("主機切斷連線:原因是對端關閉", .timeLimit(.minutes(1)))
    func peerCloseIsRecorded() async throws {
        let server = try await TestSSHServer.start { command in command == "send" ? .dropConnection : .reply(stdout: "ok") }
        defer { server.stop() }
        let events = Events()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, diagnostics: events.observer)

        _ = try? await collect(channel.execute("send"))
        try await eventually { !events.dropReasons.isEmpty }

        #expect(events.dropReasons == [.closedByPeer])
        await channel.disconnect()
    }

    @Test("注入的診斷 closure 不在 event loop 上執行(NIO 執行緒 stack 有限,#470)", .timeLimit(.minutes(1)))
    func diagnosticsNeverRunOnEventLoop() async throws {
        let server = try await TestSSHServer.start { command in command == "send" ? .dropConnection : .reply(stdout: "ok") }
        defer { server.stop() }
        let onLoop = Mutex<[SSHConnectionEvent]>([])
        let all = Mutex<Int>(0)
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            diagnostics: { event in
                all.withLock { $0 += 1 }
                if MultiThreadedEventLoopGroup.currentEventLoop != nil { onLoop.withLock { $0.append(event) } }
            })

        _ = try? await collect(channel.execute("send"))
        try await eventually { all.withLock { $0 } >= 2 }  // connected + dropped

        #expect(onLoop.withLock { $0 }.isEmpty, "event loop 上呼叫了注入的診斷:\(onLoop.withLock { $0 })")
        await channel.disconnect()
    }

    @Test("呼叫 disconnect():原因是 app 要求關閉，且只記一次", .timeLimit(.minutes(1)))
    func requestedDisconnectIsRecorded() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "ok") }
        defer { server.stop() }
        let events = Events()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, diagnostics: events.observer)

        _ = try await collect(channel.execute("first"))
        await channel.disconnect()
        try await eventually { !events.dropReasons.isEmpty }
        await channel.disconnect()

        #expect(events.dropReasons == [.disconnectRequested])
    }

    @Test("撥號失敗記錄 dialFailed 與原因")
    func dialFailureIsRecorded() async throws {
        let events = Events()
        let channel = SSHHostChannel(
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "demo"), hostKeyPin: nil, diagnostics: events.observer)

        _ = try? await channel.execute("true")

        #expect(events.all == [.dialFailed(dial: 1, error: .connectionRefused)])
    }
}
