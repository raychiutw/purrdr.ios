import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

@MainActor
@Suite("Agent 列表")
struct AgentListModelTests {
    static let bridge = HerdrCommand.bridge()

    @Test("載入後依 Agent 狀態分組：工作中在閒置之前，每列有標題與「種類 · 資料夾」副標")
    func groupsAgentsByStatus() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson"))
        let model = AgentListModel(client: HerdrClient(channel: host))

        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.sections == [
            AgentSection(group: .working, rows: [
                AgentRow(id: "w1:pA", title: "規劃天氣小工具", subtitle: "Claude Code · Projects", status: .working),
                AgentRow(id: "w1:pB", title: "重構食譜匯入", subtitle: "Claude Code · recipe-box", status: .working),
            ]),
            AgentSection(group: .idle, rows: [
                AgentRow(id: "w1:p6", title: "整理植物照片的標籤", subtitle: "Claude Code · garden-journal", status: .idle),
            ]),
        ])
    }

    @Test("主機回錯誤時，列表顯示 herdr 的原文而不是原始 JSON")
    func showsHerdrMessageOnFailure() async {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("error.invalid-request.ndjson"))
        let model = AgentListModel(client: HerdrClient(channel: host))

        await model.load()

        #expect(model.phase == .failed("invalid request: key must be a string at line 1 column 56"))
        #expect(model.sections.isEmpty)
    }
}
