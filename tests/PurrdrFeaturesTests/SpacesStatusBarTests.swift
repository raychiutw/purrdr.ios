import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Workspace 群組收合標頭的狀態條(#103 故事 10–12)。
///
/// 錄製的 snapshot:`w1`(garden-journal)`w1:p6` idle、`w1:pA`／`w1:pB` working;`w2` 只有 shell。
@MainActor
@Suite("Spaces 檢視的狀態條")
struct SpacesStatusBarTests {
    /// 以 `w1:p6` 為底複製 Agent(`agents[]` 與 `panes[]` 都加),pane id 是 `w1:c<序號>`。
    static func addAgents(_ statuses: [String], to response: inout [String: Any]) {
        var result = response["result"] as? [String: Any] ?? [:]
        var snapshot = result["snapshot"] as? [String: Any] ?? [:]
        for key in ["agents", "panes"] {
            var items = snapshot[key] as? [[String: Any]] ?? []
            guard let template = items.first(where: { $0["pane_id"] as? String == "w1:p6" }) else { continue }
            for (index, status) in statuses.enumerated() {
                var copy = template
                copy["pane_id"] = "w1:c\(index)"
                if key == "agents" {
                    copy["agent_status"] = status
                    copy.removeValue(forKey: "agent_session")
                }
                items.append(copy)
            }
            snapshot[key] = items
        }
        result["snapshot"] = snapshot
        response["result"] = result
    }

    static func group(_ workspaceID: String, in model: HostsModel) -> WorkspaceGroup? {
        model.agentList.spacesSections.flatMap(\.items).lazy.compactMap { item -> WorkspaceGroup? in
            if case .group(let group) = item, group.workspaceID == workspaceID { group } else { nil }
        }.first
    }

    @Test("20 個以內每個 Agent 一段，依需要你 > 工作中 > 完成 > 閒置排序")
    func onePerAgentSortedByUrgency() async throws {
        let model = await SpacesViewTests.model { response in
            SnapshotEdit.agent("w1:pB", in: &response) { $0["agent_status"] = "blocked" }
        }
        // `w1:p6`(idle)有沒讀過的回覆 → 完成。
        model.agentList.list(for: .demo)?.previews = [
            "w1:p6": MessagePreview(text: "好了", date: Date(timeIntervalSince1970: 1_800_000_000), isFromUser: false),
        ]

        let group = try #require(Self.group("w1", in: model))
        #expect(group.statusBar == [
            StatusSegment(status: .blocked, weight: 1), StatusSegment(status: .working, weight: 1), StatusSegment(status: .done, weight: 1),
        ])
    }

    @Test("剛好 20 個 Agent 仍是每個一段")
    func twentyAgentsStillOnePerAgent() async throws {
        let model = await SpacesViewTests.model { response in
            Self.addAgents(Array(repeating: "idle", count: 17), to: &response)
        }

        let group = try #require(Self.group("w1", in: model))
        #expect(group.agentCount == 20)
        #expect(group.statusBar.count == 20)
        #expect(group.statusBar.allSatisfy { $0.weight == 1 })
    }

    @Test("超過 20 個 Agent 依狀態合併，每段的權重等於該狀態的數量")
    func overTwentyMergesByStatus() async throws {
        let model = await SpacesViewTests.model { response in
            Self.addAgents(["blocked", "blocked"] + Array(repeating: "idle", count: 16), to: &response)
        }

        let group = try #require(Self.group("w1", in: model))
        #expect(group.agentCount == 21)
        #expect(group.statusBar == [
            StatusSegment(status: .blocked, weight: 2), StatusSegment(status: .working, weight: 2), StatusSegment(status: .idle, weight: 17),
        ])
    }

    @Test("沒有 Agent 的群組沒有狀態條")
    func terminalOnlyGroupHasNoBar() async throws {
        let model = await SpacesViewTests.model()

        let group = try #require(Self.group("w2", in: model))
        #expect(group.statusBar.isEmpty)
    }
}
