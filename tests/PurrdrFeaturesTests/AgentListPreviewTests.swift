import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 列表預覽只讀狀態變化、事件指名或沒有快取的 Agent,一次一個;第一次讀全部(#164)。
@MainActor
@Suite("Agent 列表預覽(增量)")
struct AgentListPreviewTests {
    static let bridge = HerdrCommand.bridge()
    static let started = FakeReply.recorded("events.subscribe.started.ndjson", keepsOpen: true)
    static let snapshot = FakeReply.recorded("session.snapshot.ndjson")
    nonisolated static let panes = ["w1:p6", "w1:pA", "w1:pB"]

    static func paneEvent(_ paneID: String) -> Data {
        Data(#"{"event":"pane.agent_status_changed","data":{"agent":"claude","agent_status":"working","pane_id":"\#(paneID)","workspace_id":"w1"}}"#.utf8) + [0x0A]
    }

    static let layoutUpdatedEvent = Data(#"{"event":"layout_updated","data":{"workspace_id":"w1","tab_id":"w1:t1"}}"#.utf8) + [0x0A]

    static let workspaceEvent = Data(#"{"event":"workspace_updated","data":{"workspace_id":"w1"}}"#.utf8) + [0x0A]

    /// 指令裡讀到的 pane(依 fixture 的 pane id)。
    nonisolated static func panes(in command: String) -> [String] {
        panes.filter { command.contains($0) }
    }

    /// 開始即時更新：讀快照、訂閱、訂閱開始時對帳，三個 bridge 執行都完成後回傳。
    static func start(_ host: RoutingHost) async throws -> (AgentListModel, Task<Void, Never>) {
        let model = AgentListModel(client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host), sleep: RecordingSleeper().sleep)
        let task = Task { await model.run() }
        try await waitUntil { await host.bridge.executions.count == 3 }
        try await waitUntil { await host.bridge.executions[2].closed }
        return (model, task)
    }

    static func makeHost(thenSnapshots replies: [FakeReply]) async throws -> RoutingHost {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.transcript(), to: ".claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl")
        let host = RoutingHost(shell: shell)
        await host.bridge.expect(bridge, reply: snapshot)
        await host.bridge.expect(bridge, reply: started)
        await host.bridge.expect(bridge, reply: snapshot)
        for reply in replies {
            await host.bridge.expect(bridge, reply: reply)
        }
        return host
    }

    @Test("第一次讀到快照：一次往返讀全部 Agent;訂閱開始的對帳沒有變化就不讀")
    func firstSnapshotReadsAllThenResyncReadsNothing() async throws {
        let host = try await Self.makeHost(thenSnapshots: [Self.snapshot])
        let (model, task) = try await Self.start(host)
        defer { task.cancel() }

        await host.bridge.send(stdout: Self.paneEvent("w1:pA"), toExecution: 1)

        try await waitUntil { await host.shellCommands.count >= 2 }
        let commands = await host.shellCommands
        #expect(commands.count == 2)
        #expect(Self.panes(in: commands[0]) == Self.panes)
        #expect(Self.panes(in: commands[1]) == ["w1:pA"])
        #expect(model.previews["w1:p6"] != nil, "沒有重讀的 Agent 保留預覽")
    }

    @Test("事件指名的 pane:只讀那一個 Agent")
    func namedPaneReadsOnlyThatAgent() async throws {
        let host = try await Self.makeHost(thenSnapshots: [Self.snapshot])
        let (_, task) = try await Self.start(host)
        defer { task.cancel() }

        await host.bridge.send(stdout: Self.paneEvent("w1:pB"), toExecution: 1)

        try await waitUntil { await host.shellCommands.count >= 2 }
        let commands = await host.shellCommands
        #expect(commands.count == 2)
        #expect(Self.panes(in: commands[1]) == ["w1:pB"])
    }

    @Test("事件沒指名 pane、快照也沒變：不讀預覽")
    func unchangedSnapshotReadsNothing() async throws {
        let host = try await Self.makeHost(thenSnapshots: [Self.snapshot, Self.snapshot])
        let (_, task) = try await Self.start(host)
        defer { task.cancel() }

        await host.bridge.send(stdout: Self.workspaceEvent, toExecution: 1)
        try await waitUntil { await host.bridge.executions.count == 4 }
        await host.bridge.send(stdout: Self.paneEvent("w1:pA"), toExecution: 1)

        try await waitUntil { await host.bridge.consumedAll(executions: 5) }
        try await waitUntil { await host.shellCommands.count >= 2 }
        #expect(await host.shellCommands.count == 2, "workspace 事件不讀預覽，只有指名 w1:pA 的那次")
    }

    @Test("快照裡狀態變了的 Agent 合併成一個請求讀")
    func statusChangesReadChangedAgentsInOneRequest() async throws {
        let changed = FakeReply.recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent("w1:p6", in: &$0) { $0["agent_status"] = "working" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        }
        let host = try await Self.makeHost(thenSnapshots: [changed])
        let (_, task) = try await Self.start(host)
        defer { task.cancel() }

        await host.bridge.send(stdout: Self.workspaceEvent, toExecution: 1)

        try await waitUntil { await host.shellCommands.count >= 2 }
        try await Task.sleep(for: .milliseconds(200))
        let commands = await host.shellCommands
        #expect(commands.count == 2)
        #expect(Self.panes(in: commands[1]) == ["w1:p6", "w1:pB"])
    }

    @Test("預覽讀取很慢：不擋住快照與訂閱(「需要你」不被延遲)")
    func slowPreviewsDoNotDelaySnapshots() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await connection.expect("events.subscribe", reply: Fixtures.data("events.subscribe.started.ndjson"))
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        await connection.holdTranscripts()
        let model = AgentListModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), sleep: RecordingSleeper().sleep)
        let task = Task { await model.run() }
        defer {
            task.cancel()
            Task { await connection.releaseTranscripts() }
        }

        try await waitUntil { await !connection.transcriptRequests.isEmpty }
        try await waitUntil { await connection.requests.count == 3 }
        #expect(await connection.unmetExpectations.isEmpty)
    }

    @Test("Spaces 檢視的版面事件：只重讀快照，不讀預覽")
    func layoutEventReadsNoPreviews() async throws {
        let host = try await Self.makeHost(thenSnapshots: [Self.snapshot])
        let model = AgentListModel(client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host), sleep: RecordingSleeper().sleep)
        model.subscribesToLayout = true
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { await host.bridge.executions.count == 3 }
        try await waitUntil { await host.bridge.executions[2].closed }
        try await waitUntil { await MainActor.run { !model.previews.isEmpty } }
        let readsBefore = await host.shellCommands.count

        await host.bridge.send(stdout: Self.layoutUpdatedEvent, toExecution: 1)

        try await waitUntil { await host.bridge.consumedAll(executions: 4) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await host.shellCommands.count == readsBefore)
        #expect(await host.bridge.executions[1].stdinText.contains(#""type":"layout.updated""#))
    }

    @Test("列表可見時，一直在工作、狀態沒變的 Agent 每 30 秒更新一次預覽(閒置的不讀;對話紀錄沒變的只問大小)")
    func workingAgentsRefreshEvery30Seconds() async throws {
        let host = try await Self.makeHost(thenSnapshots: [])
        let shell = await host.shell
        try shell.write(Fixtures.transcript(), to: ".claude/projects/-Users-demo-Projects/00000000-0000-0000-0000-000000000002.jsonl")
        try shell.write(Fixtures.transcript(), to: ".claude/projects/-Users-demo-Projects-recipe-box/00000000-0000-0000-0000-000000000003.jsonl")
        let clock = SimulatedClock()
        let model = AgentListModel(client: HerdrClient(channel: host), transcripts: TranscriptReader(channel: host), sleep: clock.sleep)
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { await host.bridge.executions.count == 3 }
        try await waitUntil { await host.bridge.executions[2].closed }
        try await waitUntil { await host.shellCommands.count == 1 }

        try await waitUntil { await clock.nextDeadline != nil }
        await clock.advance(to: .seconds(30))

        try await waitUntil { await host.shellCommands.filter { !Self.panes(in: $0).isEmpty }.count >= 2 }
        var previewReads = await host.shellCommands.filter { !Self.panes(in: $0).isEmpty }
        #expect(previewReads.count == 2)
        #expect(Self.panes(in: previewReads[1]) == ["w1:pA", "w1:pB"])

        try await waitUntil { await clock.nextDeadline == .seconds(60) }
        let commandsBefore = await host.shellCommands.count
        await clock.advance(to: .seconds(60))
        try await waitUntil { await host.shellCommands.count >= commandsBefore + 2 }
        try await Task.sleep(for: .milliseconds(200))
        previewReads = await host.shellCommands.filter { !Self.panes(in: $0).isEmpty }
        #expect(previewReads.count == 2, "對話紀錄沒變：只問大小，不再讀預覽")
    }
}
