import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// HTTPS 的 Pane 終端機(#61):主機服務轉接 `herdr terminal session control` 的 NDJSON。
/// 經真正的 WebSocket(URLSession)連假的主機服務，從 `PaneTerminalClient` 這一端驗證，並與 SSH 路線解出的事件比對。
@Suite("HTTPS Pane 終端機")
struct HTTPSPaneTerminalTests {
    private static func client(_ service: FakeHostService, token: String = "token-ok") -> PaneTerminalClient {
        PaneTerminalClient(connection: HTTPSHostConnection(address: service.address, deviceToken: { token }))
    }

    private static func collect(_ connection: PaneTerminalConnection) async -> [PaneTerminalEvent] {
        var events: [PaneTerminalEvent] = []
        for await event in connection.events { events.append(event) }
        return events
    }

    /// 同一份錄製檔經 SSH 路線(假主機回放 stdout)解出的事件。
    private static func sshEvents(_ fixture: String) async throws -> [PaneTerminalEvent] {
        let host = FakeHost()
        await host.expect(HerdrCommand.terminalSessionControl(target: "w1:p1", columns: 40, rows: 12), reply: FakeReply(keepsOpen: true))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)
        for line in Fixtures.sessionControlLines(fixture) {
            await host.send(.stdout(line + [0x0A]), toExecution: 0)
        }
        await host.finish(execution: 0)
        return await collect(connection)
    }

    @Test("錄製的畫面經主機服務轉接後，與 SSH 路線解出的事件相同;release 後收到 detached")
    func framesMatchSSHRoute() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12)
        await connection.release()
        let events = await Self.collect(connection)

        #expect(events == (try await Self.sshEvents("01-handshake-echo-release.stdout.ndjson")))
        #expect(events.count == 4)
        let open = try #require(service.messages(ofType: "pane.terminal.open").first)
        #expect(open["target"] as? String == "w1:p1")
        #expect(open["columns"] as? Int == 40)
        #expect(open["rows"] as? Int == 12)
        #expect(open["takeover"] as? Bool != true)
        #expect(connection.isViewOnly == false)
    }

    @Test("輸入、resize、捲動與 release 以主機服務協定送出，帶開啟請求的串流識別碼")
    func inputsUseHostServiceMessages() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12)

        try await connection.send(bytes: Data([0x15]))
        try await connection.send(.resize(columns: 60, rows: 15))
        try await connection.send(.scroll(.down, lines: 2, column: 3, row: 4))
        await connection.release()
        _ = await Self.collect(connection)

        let streamID = try #require(service.messages(ofType: "pane.terminal.open").first?["request_id"] as? String)
        #expect(service.messages(ofType: "pane.terminal.input") == [
            Self.object(#"{"type":"pane.terminal.input","stream_id":"\#(streamID)","bytes":"FQ=="}"#),
        ])
        #expect(service.messages(ofType: "pane.terminal.resize") == [
            Self.object(#"{"type":"pane.terminal.resize","stream_id":"\#(streamID)","columns":60,"rows":15}"#),
        ])
        #expect(service.messages(ofType: "pane.terminal.scroll") == [
            Self.object(#"{"type":"pane.terminal.scroll","stream_id":"\#(streamID)","direction":"down","lines":2,"column":3,"row":4}"#),
        ])
        #expect(service.messages(ofType: "pane.terminal.close") == [
            Self.object(#"{"type":"pane.terminal.close","stream_id":"\#(streamID)"}"#),
        ])
    }

    private static func object(_ json: String) -> NSDictionary {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? NSDictionary ?? [:]
    }

    @Test("接管時帶 takeover")
    func takeover() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }

        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12, takeover: true)
        await connection.release()

        #expect(service.messages(ofType: "pane.terminal.open").first?["takeover"] as? Bool == true)
    }

    @Test("herdr 結束的原因與沒有 terminal.closed 的斷線，分類與 SSH 路線相同", arguments: [
        "13-not-found-control.stdout.ndjson", "14-exited-control.stdout.ndjson", "06-takeover-B.stdout.ndjson",
        "06-takeover-A.stdout.ndjson", "11-oversize-input-disconnect.stdout.ndjson",
    ])
    func endingsMatchSSHRoute(fixture: String) async throws {
        let service = try await FakeHostService.start(.init(paneTerminalReply: .replay(fixture)))
        defer { Task { await service.stop() } }

        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12)

        #expect(await Self.collect(connection) == (try await Self.sshEvents(fixture)))
    }

    @Test("herdr 沒跑起來：失敗並帶 exit code 與 stderr")
    func herdrFailure() async throws {
        let service = try await FakeHostService.start(.init(paneTerminalReply: .failed(exitCode: 3, message: "herdr: cannot connect")))
        defer { Task { await service.stop() } }

        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12)

        #expect(await Self.collect(connection) == [.failed(exitCode: 3, message: "herdr: cannot connect")])
    }

    @Test("唯讀裝置：連線標示只能看，仍收得到畫面")
    func readOnlyDeviceWatchesOnly() async throws {
        let service = try await FakeHostService.start(.init(readOnlyTokens: ["token-ok"]))
        defer { Task { await service.stop() } }

        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12)
        await connection.release()
        let events = await Self.collect(connection)

        #expect(connection.isViewOnly)
        #expect(events.contains { if case .frame = $0 { true } else { false } })
    }

    @Test("WSS 斷線：Pane 終端機以 disconnected 結束(可以重新連線)")
    func droppedConnectionDisconnects() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let connection = try await Self.client(service).control(target: "w1:p1", columns: 40, rows: 12)

        await service.dropConnections()
        let events = await Self.collect(connection)

        #expect(events.last == .disconnected)
    }

    @Test("Agent 列表與 Pane 終端機共用同一條 WSS")
    func sharesOneConnection() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })

        _ = try await HerdrClient(connection: connection).snapshot()
        let terminal = try await PaneTerminalClient(connection: connection).control(target: "w1:p1", columns: 40, rows: 12)
        await terminal.release()
        _ = await Self.collect(terminal)

        #expect(service.log.connections == 1)
    }
}
