import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Workspace 群組的展開與收合(#103 故事 14–17、31)。
///
/// 錄製的 snapshot:`w1`(garden-journal)`w1:p6` idle、`w1:pA`／`w1:pB` working;`w2`(scratch)只有 shell。
@MainActor
@Suite("Spaces 檢視的群組展開")
struct SpacesExpansionTests {
    static let studio = UnreadPinnedTests.studio
    static let t0 = UnreadPinnedTests.t0

    static func group(_ workspaceID: String, in model: MergedAgentListModel) -> WorkspaceGroup? {
        model.spacesSections.flatMap(\.items).lazy.compactMap { item -> WorkspaceGroup? in
            if case .group(let group) = item, group.workspaceID == workspaceID { group } else { nil }
        }.first
    }

    static func model(snapshots: [((inout [String: Any]) -> Void)?] = [nil]) async -> MergedAgentListModel {
        let studio = await UnreadPinnedTests.host(Self.studio, clock: MarkerClock(Self.t0), snapshots: snapshots)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()
        return model
    }

    @Test("預設：有需要你或工作中的群組展開，其他收合")
    func defaultExpandsBusyGroups() async throws {
        let busy = await Self.model()
        #expect(Self.group("w1", in: busy)?.isExpanded == true)
        #expect(Self.group("w2", in: busy)?.isExpanded == false)

        let quiet = await Self.model(snapshots: [{
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "idle" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "done" }
        }])
        #expect(Self.group("w1", in: quiet)?.isExpanded == false)

        let needsYou = await Self.model(snapshots: [{
            SnapshotEdit.agent("w1:pA", in: &$0) { $0["agent_status"] = "idle" }
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        }])
        #expect(Self.group("w1", in: needsYou)?.isExpanded == true)
    }

    @Test("點標頭切換展開;手動狀態覆蓋預設規則，列表更新後保留")
    func manualToggleSurvivesUpdates() async throws {
        // 第二次讀取：`w1:pB` 變成需要你(預設規則仍是展開),`w2` 仍只有 shell(預設收合)。
        let model = await Self.model(snapshots: [nil, {
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        }])

        model.toggleExpanded(try #require(Self.group("w1", in: model)))
        model.toggleExpanded(try #require(Self.group("w2", in: model)))
        #expect(Self.group("w1", in: model)?.isExpanded == false)
        #expect(Self.group("w2", in: model)?.isExpanded == true)

        await model.load()
        #expect(Self.group("w1", in: model)?.counts.needsYou == 1, "第二次讀取沒有生效")
        #expect(Self.group("w1", in: model)?.isExpanded == false)
        #expect(Self.group("w2", in: model)?.isExpanded == true)

        model.toggleExpanded(try #require(Self.group("w1", in: model)))
        #expect(Self.group("w1", in: model)?.isExpanded == true)
    }

    @Test("搜尋時命中的群組一律展開;清掉搜尋後回到手動狀態")
    func searchExpandsMatchesWithoutOverwritingManualState() async throws {
        let model = await Self.model()
        model.toggleExpanded(try #require(Self.group("w1", in: model)))

        model.query = "garden"
        #expect(Self.group("w1", in: model)?.isExpanded == true)
        model.query = "scratch"
        #expect(Self.group("w2", in: model)?.isExpanded == true)

        model.query = ""
        #expect(Self.group("w1", in: model)?.isExpanded == false)
        #expect(Self.group("w2", in: model)?.isExpanded == false)
    }

    @Test("搜尋時也能收合與展開：只作用在這次搜尋，搜尋字改變或清空就丟掉，不改手動狀態")
    func toggleDuringSearchIsScopedToSearch() async throws {
        let model = await Self.model()
        model.toggleExpanded(try #require(Self.group("w2", in: model)))

        model.query = "garden"
        model.toggleExpanded(try #require(Self.group("w1", in: model)))
        #expect(Self.group("w1", in: model)?.isExpanded == false, "搜尋時點標頭沒有收合")
        model.toggleExpanded(try #require(Self.group("w1", in: model)))
        #expect(Self.group("w1", in: model)?.isExpanded == true, "搜尋時再點沒有展開")
        model.toggleExpanded(try #require(Self.group("w1", in: model)))

        model.query = "garden-j"
        #expect(Self.group("w1", in: model)?.isExpanded == true, "搜尋字改變後應丟掉這次搜尋的切換")
        model.toggleExpanded(try #require(Self.group("w1", in: model)))

        model.query = ""
        #expect(Self.group("w1", in: model)?.isExpanded == true, "清掉搜尋後應回到預設(工作中展開)")
        #expect(Self.group("w2", in: model)?.isExpanded == true, "搜尋前的手動狀態被改掉")
    }
}
