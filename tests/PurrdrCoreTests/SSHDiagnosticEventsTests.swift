import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrSSH
import Synchronization
import Testing

/// SSH 斷線與逾時經診斷事件寫進可分享的診斷檔(#688):有中斷原因,沒有主機位址。
/// 對本機的測試用 SSH 伺服器跑,期限以手動時鐘推進;前例:`SSHConnectionDiagnosticsTests`。
@Suite("SSH 診斷事件進診斷檔")
struct SSHDiagnosticEventsTests {
    final class MemorySink: DiagnosticLogStoring, Sendable {
        private let stored = Mutex<[DiagnosticEntry]>([])
        var entries: [DiagnosticEntry] { stored.withLock { $0 } }
        func append(_ entries: [DiagnosticEntry]) { stored.withLock { $0.append(contentsOf: entries) } }
        func exportFile(meta: DiagnosticEntry?) async -> URL? { nil }
        func clear() async {}
        var records: [DiagnosticEventRecord] { entries.compactMap { if case .event(let record) = $0 { record } else { nil } } }
        var lines: [String] { entries.map(DiagnosticLogEncoder.line) }
    }

    static func hub(_ sink: MemorySink, enabled: Bool = true) -> DiagnosticEvents {
        DiagnosticEvents(sink: sink, isEnabled: { enabled }, console: { _ in })
    }

    @Test("主機不回 keepalive:診斷檔有 connected 與 keepalive 逾時的中斷,不含主機位址", .timeLimit(.minutes(1)))
    func keepaliveTimeoutReachesTheFile() async throws {
        let server = try await TestSSHServer.start(keepalive: .ignore) { _ in .reply(stdout: "ok") }
        let clock = ManualSSHClock()
        let sink = MemorySink()
        let events = Self.hub(sink)
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            timeouts: SSHTimeouts(keepaliveInterval: .milliseconds(100), keepaliveReply: .milliseconds(200)), scheduler: clock,
            diagnostics: SSHConnectionLog.events(events, host: server.endpoint.host))

        _ = try await collect(channel.execute("first"))
        await clock.advance(by: .milliseconds(100))
        await clock.advance(by: .milliseconds(100))
        try await eventually { server.snapshot.keepalives == 1 }
        await clock.advance(by: .milliseconds(200))
        try await eventually { sink.records.contains { $0.code == "dropped" } }

        let records = sink.records
        #expect(records.map(\.code) == ["connected", "dropped"])
        #expect(records[1].reason == "keepalive_timeout")
        #expect(records.allSatisfy { $0.host == 1 && $0.category == "ssh" })
        for line in sink.lines { #expect(!line.contains(server.endpoint.host), "診斷檔含主機位址:\(line)") }
        await channel.disconnect()
        await server.stop()
    }

    @Test("主機切斷連線:原因是對端關閉", .timeLimit(.minutes(1)))
    func peerCloseReachesTheFile() async throws {
        let server = try await TestSSHServer.start { command in command == "send" ? .dropConnection : .reply(stdout: "ok") }
        let sink = MemorySink()
        let events = Self.hub(sink)
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            diagnostics: SSHConnectionLog.events(events, host: server.endpoint.host))

        _ = try? await collect(channel.execute("send"))
        try await eventually { sink.records.contains { $0.code == "dropped" } }

        #expect(sink.records.last?.reason == "closed_by_peer")
        await channel.disconnect()
        await server.stop()
    }

    @Test("撥號失敗:只記錯誤種類", .timeLimit(.minutes(1)))
    func dialFailureReachesTheFile() async throws {
        let sink = MemorySink()
        let events = Self.hub(sink)
        let channel = SSHHostChannel(
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "demo"), hostKeyPin: nil,
            diagnostics: SSHConnectionLog.events(events, host: "127.0.0.1"))

        _ = try? await channel.execute("true")
        await events.flush()

        #expect(sink.records.map(\.code) == ["dial_failed"])
        #expect(sink.records.first?.reason == "connectionRefused")
        for line in sink.lines { #expect(!line.contains("127.0.0.1")) }
    }

    @Test("「操作記錄」關閉:不寫連線事件", .timeLimit(.minutes(1)))
    func disabledWritesNothing() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "ok") }
        let sink = MemorySink()
        let events = Self.hub(sink, enabled: false)
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            diagnostics: SSHConnectionLog.events(events, host: server.endpoint.host))

        _ = try await collect(channel.execute("first"))
        await channel.disconnect()
        await events.flush()

        #expect(sink.entries.isEmpty)
        await server.stop()
    }
}
