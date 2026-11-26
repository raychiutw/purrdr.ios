import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 型別化主機操作(ADR-0015、#594):SSH 經 herdr NDJSON 與腳本格式、HTTPS 直接對應主機服務訊息，
/// 兩種連線方式對同一個型別化介面給出相同的值;`FakeHostConnection` 也能直接回型別化的值。
@Suite("型別化主機連線操作")
struct TypedHostConnectionTests {
    static let bridgeCommand = HerdrClientTests.bridgeCommand
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let cwd = "/Users/demo/Projects/garden-journal"
    static let path = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"
    static let location = TranscriptLocation(locator: .claude, reference: .id(sessionID), cwd: cwd)

    // MARK: - SSH(錄製 fixture 與腳本輸出)

    @Test("SSH 讀 snapshot:送 session.snapshot,型別化的值與 HerdrClient 解出的相同")
    func sshSnapshot() async throws {
        let host = FakeHost()
        await host.expect(Self.bridgeCommand, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.bridgeCommand, reply: .recorded("session.snapshot.ndjson"))
        let connection = SSHHostConnection(channel: host)

        let typed = try await connection.readSnapshot()
        let viaClient = try await HerdrClient(connection: connection).snapshot()

        #expect(typed == viaClient)
        #expect(typed.agents.count == 3)
        let first = try #require(await host.executions.first)
        #expect(first.stdinText == #"{"id":"purrdr:session.snapshot","method":"session.snapshot","params":{}}"# + "\n")
    }

    @Test("SSH 送鍵與送文字:一行 pane.send_keys／pane.send_text,SSH 不帶比對欄位")
    func sshSendKeysAndText() async throws {
        let host = FakeHost()
        let ok = FakeReply(stdout: Data(#"{"id":"purrdr:x","result":{"type":"ok"}}"#.utf8 + [0x0A]), trigger: .afterStdinLine)
        await host.expect(Self.bridgeCommand, reply: ok)
        await host.expect(Self.bridgeCommand, reply: ok)
        let connection = SSHHostConnection(channel: host)

        try await connection.sendKeys(paneID: "w1:p6", keys: ["down", "enter"], expecting: SendExpectation(session: Self.sessionID))
        try await connection.sendText(paneID: "w1:p6", text: "hi", expecting: SendExpectation(session: Self.sessionID))

        let stdin = await host.executions.compactMap(\.stdinText)
        #expect(stdin == [
            #"{"id":"purrdr:pane.send_keys","method":"pane.send_keys","params":{"keys":["down","enter"],"pane_id":"w1:p6"}}"# + "\n",
            #"{"id":"purrdr:pane.send_text","method":"pane.send_text","params":{"pane_id":"w1:p6","text":"hi"}}"# + "\n",
        ])
    }

    @Test("SSH 讀畫面:pane.read visible,回傳錄製的畫面文字")
    func sshReadPane() async throws {
        let host = FakeHost()
        await host.expect(Self.bridgeCommand, reply: .recorded("pane.read.agents-pane.ndjson"))

        let screen = try await SSHHostConnection(channel: host).readPaneScreen(paneID: "w1:pA", lines: 40, format: .text)

        #expect(screen.contains("The CSV export change is merged"))
        let stdin = try #require(await host.executions.first?.stdinText)
        #expect(stdin.contains(#""source":"visible""#) && stdin.contains(#""lines":40"#))
    }

    @Test("SSH 定位與讀視窗:解析腳本輸出成 TranscriptFile 與 TranscriptChunk")
    func sshLocateAndWindow() async throws {
        let host = FakeHost()
        await host.expect(TranscriptCommand.locate(Self.location), reply: FakeReply(stdout: Data("\(Self.path)\n48213\n".utf8)))
        await host.expect(
            TranscriptCommand.window(path: Self.path, end: 140, lines: 300, chunkBytes: 4 << 20, maxBytes: 0),
            reply: FakeReply(stdout: Data("100 130\n20\t{\"n\":1}\n8\t{\"n\":2}\n".utf8)))
        let connection = SSHHostConnection(channel: host)

        let file = try await connection.locateTranscript(Self.location)
        let chunk = try await connection.readTranscriptWindow(path: Self.path, end: 140, lines: 300, maxBytes: 0)

        #expect(file == TranscriptFile(path: Self.path, size: 48213))
        #expect(chunk == TranscriptChunk(start: 100, end: 130, lines: [#"{"n":1}"#, #"{"n":2}"#]))
    }

    // MARK: - HTTPS(直接對應主機服務訊息)

    private static func connection(to service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9")
    }

    private static func sent(_ service: FakeHostService, type: String) throws -> [String: Any] {
        let messages = service.log.messages.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return try #require(messages.last { $0["type"] as? String == type })
    }

    @Test("HTTPS 讀 snapshot:送 agents.list,型別化的值與經 herdr 格式組回再解出的相同")
    func httpsSnapshot() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        let typed = try await connection.readSnapshot()
        let viaClient = try await HerdrClient(connection: connection).snapshot()

        #expect(typed == viaClient)
        #expect(!typed.agents.isEmpty)
        #expect(try Self.sent(service, type: "agents.list")["type"] as? String == "agents.list")
    }

    @Test("HTTPS 送鍵與送文字:帶 pane_id 與 expected_session(主機服務 0.7.0 起)")
    func httpsSendKeysAndText() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)
        let expecting = SendExpectation(session: "00000000-0000-0000-0000-000000000001")

        try await connection.sendKeys(paneID: "w1:p6", keys: ["down", "enter"], expecting: expecting)
        try await connection.sendText(paneID: "w1:p6", text: "hi", expecting: expecting)

        let keys = try Self.sent(service, type: "pane.send_keys")
        #expect(keys["pane_id"] as? String == "w1:p6")
        #expect(keys["keys"] as? [String] == ["down", "enter"])
        #expect(keys["expected_session"] as? String == expecting.session)
        let text = try Self.sent(service, type: "pane.send_text")
        #expect(text["text"] as? String == "hi")
        #expect(text["expected_session"] as? String == expecting.session)
    }

    @Test("HTTPS 送出時 session 已換:丟 paneChanged(什麼都沒送出)")
    func httpsSendKeysPaneChanged() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0", paneSessions: ["w1:p6": "another"]))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.paneChanged) {
            try await Self.connection(to: service).sendKeys(paneID: "w1:p6", keys: ["1"], expecting: SendExpectation(session: Self.sessionID))
        }
    }

    @Test("HTTPS 讀畫面:pane.read visible;ansi 帶 format;主機服務太舊要求更新")
    func httpsReadPane() async throws {
        let service = try await FakeHostService.start(.init(
            hostServiceVersion: "0.7.0", paneScreens: ["w1:p6": "plain"], ansiPaneScreens: ["w1:p6": "\u{1B}[2mansi"]))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        #expect(try await connection.readPaneScreen(paneID: "w1:p6", lines: 40, format: .text) == "plain")
        #expect(try Self.sent(service, type: "pane.read")["format"] == nil)
        #expect(try await connection.readPaneScreen(paneID: "w1:p6", lines: 40, format: .ansi) == "\u{1B}[2mansi")
        #expect(try Self.sent(service, type: "pane.read")["format"] as? String == "ansi")

        let old = try await FakeHostService.start(.init(hostServiceVersion: "0.6.0"))
        defer { Task { await old.stop() } }
        await #expect(throws: HostServiceError.self) {
            _ = try await Self.connection(to: old).readPaneScreen(paneID: "w1:p6", lines: 40, format: .text)
        }
    }

    @Test("HTTPS 定位與讀視窗:transcript.locate／transcript.window 直接換成型別化的值")
    func httpsLocateAndWindow() async throws {
        let service = try await FakeHostService.start(.init(transcriptReplies: [
            "transcript.locate": #"{"type":"transcript.locate.result","path":"\#(Self.path)","size":48213}"#,
            "transcript.window": #"{"type":"transcript.window.result","start":100,"end":130,"records":[{"length":20,"text":"{\"n\":1}"},{"length":8,"text":"{\"n\":2}"}]}"#,
        ]))
        defer { Task { await service.stop() } }
        let connection = Self.connection(to: service)

        let file = try await connection.locateTranscript(Self.location)
        let chunk = try await connection.readTranscriptWindow(path: Self.path, end: 140, lines: 300, maxBytes: 0)

        #expect(file == TranscriptFile(path: Self.path, size: 48213))
        #expect(chunk == TranscriptChunk(start: 100, end: 130, lines: [#"{"n":1}"#, #"{"n":2}"#]))
        #expect(try Self.sent(service, type: "transcript.locate")["session"] != nil)
    }

    @Test("HTTPS 讀視窗:範圍與行長度加總對不上就是 changed(重試)")
    func httpsWindowInconsistentIsChanged() async throws {
        let service = try await FakeHostService.start(.init(transcriptReplies: [
            "transcript.window": #"{"type":"transcript.window.result","start":100,"end":130,"records":[{"length":3,"text":"{}"}]}"#,
        ]))
        defer { Task { await service.stop() } }

        await #expect(throws: TranscriptReadError.changed) {
            _ = try await Self.connection(to: service).readTranscriptWindow(path: Self.path, end: 140, lines: 300, maxBytes: 0)
        }
    }

    @Test("定位對話紀錄:不安全的位置不送出(兩種連線方式一致)")
    func unsafeLocationIsRejected() async throws {
        let unsafe = TranscriptLocation(locator: .claude, reference: .id("../etc"), cwd: Self.cwd)
        let service = try await FakeHostService.start(.init())
        defer { Task { await service.stop() } }

        await #expect(throws: TranscriptReadError.invalidReference) { _ = try await Self.connection(to: service).locateTranscript(unsafe) }
        await #expect(throws: TranscriptReadError.invalidReference) { _ = try await SSHHostConnection(channel: FakeHost()).locateTranscript(unsafe) }
    }

    // MARK: - FakeHostConnection

    @Test("FakeHostConnection 回型別化的值並記錄呼叫;沒設定的操作走既有的 herdr 回放")
    func fakeConnectionReturnsTypedValues() async throws {
        let connection = FakeHostConnection()
        let snapshot = HostSnapshot(version: "9.9", agents: [Agent(paneID: "w1:p1", workspaceID: "w1", kind: "claude", status: .idle)])
        await connection.stub(snapshot: snapshot)
        await connection.stub(paneScreen: "screen")
        await connection.stub(transcriptFile: TranscriptFile(path: Self.path, size: 7))
        await connection.stub(transcriptChunk: TranscriptChunk(start: 0, end: 3, lines: ["{}"]))

        #expect(try await connection.readSnapshot() == snapshot)
        let ok = Data(#"{"id":"purrdr:x","result":{"type":"ok"}}"#.utf8)
        await connection.expect(.sendKeys, wire: ok)
        await connection.expect(.sendText, wire: ok)
        try await connection.sendKeys(paneID: "w1:p1", keys: ["enter"], expecting: .none)
        try await connection.sendText(paneID: "w1:p1", text: "hi", expecting: SendExpectation(session: "s"))
        #expect(try await connection.readPaneScreen(paneID: "w1:p1", lines: 10, format: .ansi) == "screen")
        #expect(try await connection.locateTranscript(Self.location).size == 7)
        #expect(try await connection.readTranscriptWindow(path: Self.path, end: 3, lines: 5, maxBytes: 0).end == 3)

        let calls = await connection.typedCalls
        #expect(calls == [
            "readSnapshot", "sendKeys w1:p1 enter", "sendText w1:p1 hi", "readPaneScreen w1:p1 10 ansi",
            "locateTranscript", "readTranscriptWindow \(Self.path) 3 5 0",
        ])

        // 沒設定型別化的值:退回 herdr 請求回放(既有測試的做法)。
        await connection.expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))
        let replayed = try await connection.readSnapshot()
        #expect(replayed.version == "0.9.5")
    }
}
