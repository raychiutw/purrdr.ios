import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天列表每一列顯示 Tab 名稱(#475):人取的名稱照原文;沒有名稱(或 herdr 的預設數字名稱)用「Tab N」,
/// N 是 Tab 在 workspace 裡的順序(與 Spaces 檢視既有的規則相同)。
@MainActor
@Suite("列表的 Tab 名稱")
struct TabNameTests {
    @Test("名稱規則:人取的照原文;空白、沒有或預設數字名稱用編號")
    func nameRule() {
        #expect(AgentListProjection.tabName(label: "CSV 匯出", position: 2) == "CSV 匯出")
        #expect(AgentListProjection.tabName(label: nil, position: 2) == "Tab 2")
        #expect(AgentListProjection.tabName(label: "  ", position: 4) == "Tab 4")
        #expect(AgentListProjection.tabName(label: "3", position: 3) == "Tab 3")
    }

    @Test("Agents 列帶 Tab 名稱:有名稱用名稱,沒有名稱用在 workspace 裡的順序")
    func agentRowsCarryTabName() async throws {
        let model = await SpacesViewTests.model { response in
            SnapshotEdit.tab("w1:tA", in: &response) { $0["label"] = "CSV 匯出" }
            SnapshotEdit.tab("w1:tB", in: &response) { $0["label"] = NSNull() }
        }
        let rows = model.agentList.sections.flatMap(\.rows)
        let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.paneID, $0.tabName) })
        #expect(names["w1:pA"] == "CSV 匯出")
        #expect(names["w1:pB"] == "Tab 3")
    }

    @Test("Spaces 列帶 Tab 名稱,與標題分開(標題沒有名稱時用 Agent 標題)")
    func spacesTabsCarryTabName() async throws {
        let model = await SpacesViewTests.model { response in
            SnapshotEdit.tab("w1:tA", in: &response) { $0["label"] = "CSV 匯出" }
            SnapshotEdit.tab("w1:tB", in: &response) { $0["label"] = NSNull() }
        }
        let tabs = try #require(model.agentList.spacesSections.first).tabs
        #expect(tabs.map(\.tabName) == ["Tab 1", "CSV 匯出", "Tab 3"])
    }
}
