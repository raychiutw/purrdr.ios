import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Spaces 版面圖與聊天身分需要的 snapshot 欄位(行為規格 §3.5、F4)。
@Suite("讀 snapshot:tab、pane、版面與 session")
struct SnapshotLayoutDecodingTests {
    static let bridge = HerdrCommand.bridge()

    static func snapshot(modify: ((inout [String: Any]) -> Void)? = nil) async throws -> HostSnapshot {
        let host = FakeHost()
        let reply: FakeReply = modify.map { .recorded("session.snapshot.ndjson", modify: $0) } ?? .recorded("session.snapshot.ndjson")
        await host.expect(bridge, reply: reply)
        return try await HerdrClient(channel: host).snapshot()
    }

    @Test("workspace 帶作用中 tab;tab 帶順序與名稱")
    func decodesTabs() async throws {
        let snapshot = try await Self.snapshot()

        #expect(snapshot.workspaces.first?.activeTabID == "w1:tA")
        #expect(snapshot.tabs == [
            Tab(id: "w1:t6", workspaceID: "w1", number: 6, label: "1"),
            Tab(id: "w1:tA", workspaceID: "w1", number: 10, label: "2"),
            Tab(id: "w1:tB", workspaceID: "w1", number: 11, label: "3"),
            Tab(id: "w2:t1", workspaceID: "w2", number: 1, label: "1"),
        ])
    }

    @Test("pane 包含 agent 以外的終端機(shell),帶所在 tab 與資料夾")
    func decodesPanesIncludingShells() async throws {
        let snapshot = try await Self.snapshot()

        #expect(snapshot.panes.map(\.id) == ["w1:p6", "w1:pA", "w1:pB", "w2:p1"])
        let shell = try #require(snapshot.panes.last)
        #expect(shell == Pane(id: "w2:p1", workspaceID: "w2", tabID: "w2:t1", agentKind: nil, cwd: "/tmp/scratch"))
        #expect(snapshot.panes.first?.agentKind == "claude")
    }

    @Test("Agent 帶 session id(agent_session.value)與所在 tab;沒有 session 的是 nil")
    func decodesAgentSession() async throws {
        let snapshot = try await Self.snapshot { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_session"] = NSNull() } }

        let agent = try #require(snapshot.agents.first)
        #expect(agent.sessionID == "00000000-0000-0000-0000-000000000001")
        #expect(agent.tabID == "w1:t6")
        #expect(snapshot.agents.first { $0.paneID == "w1:pB" }?.sessionID == nil)
    }

    @Test("版面：每個 tab 的 pane 矩形(格為單位)、聚焦 pane 與 zoomed")
    func decodesLayouts() async throws {
        let snapshot = try await Self.snapshot()

        let layouts = try #require(snapshot.layouts)
        #expect(layouts.count == 4)
        #expect(layouts.first == TabLayout(
            workspaceID: "w1", tabID: "w1:t6", zoomed: false, focusedPaneID: "w1:p6",
            panes: [TabLayout.PaneRect(paneID: "w1:p6", rect: GridRect(x: 0, y: 0, width: 164, height: 32))]
        ))
    }

    @Test("版面欄位缺席(herdr 沒回報)與空陣列不同：缺席是 nil")
    func missingLayoutsIsNil() async throws {
        let snapshot = try await Self.snapshot { response in
            var result = response["result"] as? [String: Any] ?? [:]
            var snapshot = result["snapshot"] as? [String: Any] ?? [:]
            snapshot["layouts"] = nil
            result["snapshot"] = snapshot
            response["result"] = result
        }

        #expect(snapshot.layouts == nil)
    }
}
