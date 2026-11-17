import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Agent 列表只依賴主機連線(#54):以假的主機連線驅動，不經過主機通道。
@MainActor
@Suite("主機連線驅動 Agent 列表")
struct AgentListHostConnectionTests {
    static let snapshot = Fixtures.data("session.snapshot.ndjson")
    static let started = Fixtures.data("events.subscribe.started.ndjson")
    static let statusChanged = Data(
        #"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w1:pB","workspace_id":"w1","agent":"claude","agent_status":"blocked"}}"#.utf8
    )

    @Test("以主機連線讀出 Agent 列表")
    func listsAgentsFromHostConnection() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot)
        let model = AgentListModel(client: HerdrClient(connection: connection))

        await model.load()

        #expect(model.phase == .loaded)
        #expect(Set(model.sections.flatMap(\.rows).map(\.paneID)) == ["w1:p6", "w1:pA", "w1:pB"])
    }

    @Test("Agent 狀態變成 blocked 的事件到達後，那個 Agent 出現在「需要你」")
    func agentBecomesNeedsYouAfterEvent() async throws {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Self.snapshot)
        await connection.expect("events.subscribe", reply: Self.started)
        await connection.expect("session.snapshot", reply: Self.snapshot)
        // 錄製期間主機上沒有 Agent 變成 blocked:以真實回應為底，只改 w1:pB 的狀態。
        await connection.expect("session.snapshot", reply: Fixtures.modifiedLine("session.snapshot.ndjson") {
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        })
        let model = AgentListModel(client: HerdrClient(connection: connection), sleep: Sleeper(blockAfter: 1).sleep)
        let task = Task { await model.run() }
        defer { task.cancel() }
        try await waitUntil { await connection.requests.count == 3 }
        #expect(model.sections.first?.group != .needsYou)

        await connection.send(event: Self.statusChanged, toSubscription: 0)

        try await waitUntil { await MainActor.run { model.sections.first?.group == .needsYou } }
        #expect(model.sections.first?.rows.map(\.paneID) == ["w1:pB"])
        #expect(await connection.unmetExpectations.isEmpty)
    }
}
