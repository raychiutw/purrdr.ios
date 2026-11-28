import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 收集計時(可從任何執行緒呼叫)。
final class TimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [OperationTiming] = []
    var timings: [OperationTiming] { lock.withLock { items } }
    var names: [String] { timings.map(\.name) }
    lazy var sink: OperationTimingSink = { [unowned self] timing in self.lock.withLock { self.items.append(timing) } }
}

/// 續接很慢(#635):新增聊天／續接的每一步與 SSH 關鍵請求的耗時，寫進診斷記錄找出慢在哪。
@Suite("操作計時")
struct OperationTimingTests {
    static let bridge = HerdrCommand.bridge()

    @Test("續接(在既有 Workspace):記下建 Tab、啟動 Agent 與總時間，名稱標明是續接")
    func resumeRecordsEachStep() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: NewChatExistingWorkspaceTests.tabCreated())
        await host.expect(Self.bridge, reply: NewChatLaunchTests.agentStarted(pane: "w1:p3"))
        let collector = TimingCollector()
        let launcher = NewChatLauncher(
            client: HerdrClient(channel: host), folders: SSHNewChatFolders(channel: host), timings: collector.sink)

        _ = try await launcher.start(NewChatRequest(
            folder: "/Users/demo/ledger", agent: .claude, resumeSession: "abc-123", target: .existingWorkspace(id: "w1")))

        #expect(collector.names == ["resume.createTab", "resume.startAgent", "resume.total"])
        #expect(collector.timings.allSatisfy { !$0.failed && $0.milliseconds >= 0 })
    }

    @Test("新增聊天失敗的步驟標記失敗，總時間也記下")
    func failedStepIsMarked() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: NewChatLaunchTests.error("tab.create", code: "workspace_not_found", message: "gone"))
        let collector = TimingCollector()
        let launcher = NewChatLauncher(
            client: HerdrClient(channel: host), folders: SSHNewChatFolders(channel: host), timings: collector.sink)

        await #expect(throws: HerdrError.self) {
            try await launcher.start(NewChatRequest(folder: "/Users/demo/ledger", agent: .claude, target: .existingWorkspace(id: "w1")))
        }

        #expect(collector.names == ["newChat.createTab", "newChat.total"])
        #expect(collector.timings.allSatisfy { $0.failed })
    }

    @Test("SSH:關鍵 herdr 請求記下開通道與整個請求的耗時;每 2 秒的快照輪詢不記")
    func sshRecordsKeyRequestsOnly() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        await host.expect(Self.bridge, reply: FakeReply(stdout: Data(#"{"id":"purrdr:tab.close","result":{"type":"ok"}}"#.utf8 + [0x0A]), trigger: .afterStdinLine))
        let collector = TimingCollector()
        let client = HerdrClient(connection: SSHHostConnection(channel: host, timings: collector.sink))

        _ = try await client.snapshot()
        try await client.closeTab("w1:t1")

        #expect(collector.names == ["ssh.open tab.close", "ssh.request tab.close"])
    }

    @Test("SSH:對話紀錄的定位與視窗讀取記下開通道與整個指令的耗時(#659);追蹤用的讀取不記")
    func sshRecordsTranscriptLocateAndWindow() async throws {
        let host = FakeHost()
        let location = TranscriptLocation(locator: .claude, reference: .id("abc-123"), cwd: "/Users/demo/ledger")
        await host.expect(TranscriptCommand.locate(location), reply: FakeReply(stdout: Data("/t.jsonl\n10\n".utf8)))
        await host.expect(
            TranscriptCommand.window(path: "/t.jsonl", end: 10, lines: 5, chunkBytes: 1_024, maxBytes: 0),
            reply: FakeReply(stdout: Data("0 0\n".utf8)))
        await host.expect(
            TranscriptCommand.tail(path: "/t.jsonl", from: 10, limit: 100), reply: FakeReply(stdout: Data("10\n".utf8)))
        let collector = TimingCollector()
        let connection = SSHHostConnection(channel: host, timings: collector.sink)

        _ = try await connection.readTranscript(.locate(location))
        _ = try await connection.readTranscript(.window(path: "/t.jsonl", end: 10, lines: 5, chunkBytes: 1_024, maxBytes: 0))
        _ = try await connection.readTranscript(.tail(path: "/t.jsonl", from: 10, limit: 100))

        #expect(collector.names == [
            "ssh.open transcript.locate", "ssh.request transcript.locate",
            "ssh.open transcript.window", "ssh.request transcript.window",
        ])
    }
}
