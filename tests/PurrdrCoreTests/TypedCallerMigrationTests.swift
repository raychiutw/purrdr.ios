import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 型別化主機連線 2/3(#595):上層用的 `HerdrClient`／`TranscriptReader` 經連線的型別化操作，
/// 不再自己組 herdr 請求行或對話紀錄腳本的位元組。這裡的連線只設定型別化的值、沒有任何 herdr 回放,
/// 走舊路徑就會因為「沒預期的請求」而失敗。
@Suite("上層呼叫端改用型別化操作")
struct TypedCallerMigrationTests {
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let path = "/Users/demo/.claude/projects/-Users-demo-p/00000000-0000-0000-0000-000000000001.jsonl"

    @Test("HerdrClient 讀 snapshot 經 readSnapshot")
    func snapshot() async throws {
        let connection = FakeHostConnection()
        let expected = HostSnapshot(version: "9.9.9", workspaces: [], agents: [])
        await connection.stub(snapshot: expected)
        let snapshot = try await HerdrClient(connection: connection).snapshot()
        #expect(snapshot == expected)
        #expect(await connection.typedCalls == ["readSnapshot"])
    }

    @Test("HerdrClient 送鍵與送文字經型別化操作")
    func sends() async throws {
        let connection = FakeHostConnection()
        let ok = Data(#"{"id":"x","result":{"type":"ok"}}"#.utf8)
        await connection.expect("pane.send_keys", reply: ok)
        await connection.expect("pane.send_text", reply: ok)
        let client = HerdrClient(connection: connection)
        try await client.sendKeys(paneID: "w1:p1", keys: ["enter"], expecting: SendExpectation(session: "s1"))
        try await client.sendText(paneID: "w1:p1", text: "hi")
        #expect(await connection.typedCalls == ["sendKeys w1:p1 enter", "sendText w1:p1 hi"])
        #expect(await connection.requests.count == 2)
    }

    @Test("HerdrClient 讀畫面經 readPaneScreen")
    func readPane() async throws {
        let connection = FakeHostConnection()
        await connection.stub(paneScreen: "hello")
        let screen = try await HerdrClient(connection: connection).readPane(paneID: "w1:p1", lines: 20, format: .ansi)
        #expect(screen == "hello")
        #expect(await connection.typedCalls == ["readPaneScreen w1:p1 20 ansi"])
    }

    @Test("TranscriptReader 定位與讀視窗經型別化操作")
    func transcripts() async throws {
        let connection = FakeHostConnection()
        await connection.stub(transcriptFile: TranscriptFile(path: Self.path, size: 10))
        await connection.stub(transcriptChunk: TranscriptChunk(start: 0, end: 10, lines: ["{}"]))
        let reader = TranscriptReader(connection: connection)
        let file = try await reader.locate(sessionID: Self.sessionID, cwd: "/Users/demo/p")
        let chunk = try await reader.window(path: file.path, endingAt: 10, lines: 5, maxBytes: 64)
        #expect(file.size == 10)
        #expect(chunk.lines == ["{}"])
        #expect(await connection.typedCalls == ["locateTranscript", "readTranscriptWindow \(Self.path) 10 5 64"])
    }
}
