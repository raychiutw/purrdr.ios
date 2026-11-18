import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Spaces 檢視依主機分組(#103)。
///
/// 錄製的 snapshot:`w1`(garden-journal)三個 Claude(`w1:p6` idle、`w1:pA`／`w1:pB` working);
/// `w2`(scratch)只有一個 shell pane。
@MainActor
@Suite("Spaces 檢視依主機分組")
struct SpacesHostGroupingTests {
    static let studio = UnreadPinnedTests.studio
    static let lab = UnreadPinnedTests.lab
    static let t0 = UnreadPinnedTests.t0

    static func hostSections(_ model: MergedAgentListModel) -> [SpacesHost] {
        model.spacesSections.compactMap(\.host)
    }

    @Test("每台主機一組，選取中主機在前，每組都有主機名與圖示")
    func groupsByHostWithSelectedFirst() async {
        let channels = ChannelsByAddress(["studio": await MultiHostTests.healthy(), "lab": await MultiHostTests.healthy()])
        let model = MultiHostTests.model(channels)
        model.load()
        model.select(.host(MultiHostTests.lab.id))
        await model.agentList.load()

        let lab = HostSelection.host(MultiHostTests.lab.id)
        let studio = HostSelection.host(MultiHostTests.studio.id)
        let hosts = model.agentList.spacesSections.compactMap(\.host)
        #expect(hosts.map(\.host) == [lab, studio])
        #expect(hosts.map(\.name) == ["Lab", "Studio"])
        #expect(hosts.map(\.icon) == [.default, .default])
        #expect(model.agentList.spacesSections.map(\.id) == [lab.storedValue, studio.storedValue])
    }

    @Test("非選取中主機的列與終端機列不再加「主機名 ·」:主機由分組標題表示")
    func rowsCarryNoHostPrefix() async throws {
        let clock = MarkerClock(Self.t0)
        let lab = await UnreadPinnedTests.host(Self.lab, name: "Lab", clock: clock)
        let studio = await UnreadPinnedTests.host(Self.studio, name: "Studio", clock: clock)
        let model = UnreadPinnedTests.merged([studio, lab], selected: Self.studio)
        await model.load()

        let labSection = try #require(model.spacesSections.first { $0.host?.host == Self.lab })
        let rows = labSection.items.flatMap { item -> [WorkspaceGroup.Row] in
            if case .group(let group) = item { group.rows } else { [] }
        }
        let agentRows = rows.compactMap { row -> AgentRow? in if case .agent(let agent) = row { agent } else { nil } }
        let terminalRows = rows.compactMap { row -> TerminalRow? in if case .terminal(let terminal) = row { terminal } else { nil } }
        #expect(agentRows.count == 3)
        #expect(agentRows.allSatisfy { $0.hostLabel == nil && !$0.subtitle.contains("Lab") })
        #expect(terminalRows.map(\.subtitle) == ["Shell · tmp/scratch"])
    }

    @Test("主機組內：有需要你的 workspace 在前、再來是工作中，其他依 workspace 編號")
    func itemsWithinHostOrderedByUrgency() async throws {
        let clock = MarkerClock(Self.t0)
        // 改動：把 `w1:pB` 移到只有它的 `w9` 並改成需要你;`w9` 不在 workspaces 裡(編號排最後)。
        let studio = await UnreadPinnedTests.host(Self.studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:pB", in: &$0) {
                $0["workspace_id"] = "w9"
                $0["agent_status"] = "blocked"
            }
        }])
        let model = UnreadPinnedTests.merged([studio])
        await model.load()

        let section = try #require(model.spacesSections.first)
        #expect(section.items.map(\.id) == ["\(Self.studio.storedValue)/w1:pB", "\(Self.studio.storedValue)/w1", "\(Self.studio.storedValue)/w2"])
    }

    @Test("主機組標題的各狀態數量：所有 Agent,未讀的完成算完成、已讀的算閒置")
    func hostHeaderCountsAgentsByStatus() async throws {
        let clock = MarkerClock(Self.t0)
        let studio = await UnreadPinnedTests.host(Self.studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" }
        }])
        let model = UnreadPinnedTests.merged([studio])
        await model.load()
        // `w1:p6`(idle)有沒讀過的回覆 → 未讀完成。
        studio.source.list.previews = ["w1:p6": UnreadPinnedTests.preview(Self.t0.addingTimeInterval(60))]

        let header = try #require(Self.hostSections(model).first)
        #expect(header.counts == SpacesStatusCounts(needsYou: 1, working: 1, done: 1, idle: 0))
    }
}
