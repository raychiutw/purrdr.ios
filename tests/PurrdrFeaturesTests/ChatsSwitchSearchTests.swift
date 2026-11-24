import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天 tab 只有 Spaces:搜尋(#391)、主機範圍與原 Agents 檢視的情境(#501)。
@MainActor
@Suite("聊天 tab Spaces 搜尋")
struct ChatsSwitchSearchTests {
    static let studio = AgentListHostFilterTests.studio
    static let lab = AgentListHostFilterTests.lab

    @Test("Spaces 檢視搜尋 workspace 名稱：符合的 workspace 整段保留，其他段落不出現")
    func spacesSearchMatchesWorkspaceName() async {
        let model = await AgentListHostFilterTests.loadedModel()

        model.query = "garden"

        let sections = model.spacesSections
        #expect(!sections.isEmpty)
        #expect(sections.allSatisfy { $0.workspace == "garden-journal" })
        #expect(sections.allSatisfy { $0.tabs.count == 3 }, "workspace 名稱符合時段內的 Tab 不被濾掉")
    }

    @Test("Spaces 檢視搜尋 Tab 名稱：只留符合的 Tab，沒有符合 Tab 的段落不出現")
    func spacesSearchMatchesTabTitle() async {
        let model = await AgentListHostFilterTests.loadedModel()

        model.query = "食譜"

        let sections = model.spacesSections
        #expect(!sections.isEmpty)
        #expect(sections.flatMap(\.tabs).allSatisfy { $0.title.contains("食譜") })
        #expect(sections.flatMap(\.tabs).count == 2, "兩台主機各一個符合的 Tab")
    }

    @Test("Spaces 檢視搜尋找不到：沒有任何段落;清掉搜尋回到全部")
    func spacesSearchWithoutMatchAndCleared() async {
        let model = await AgentListHostFilterTests.loadedModel()
        let all = model.spacesSections

        model.query = "zzz-沒有這個"
        #expect(model.spacesSections.isEmpty)

        model.query = "  "
        #expect(model.spacesSections == all)
    }

    @Test("搜尋範圍是目前主機：選某台只搜那台，所有主機搜全部")
    func searchScopeFollowsCurrentHost() async {
        let model = await AgentListHostFilterTests.loadedModel()

        model.query = "garden"
        #expect(Set(model.spacesSections.map(\.host)) == [Self.studio, Self.lab])

        model.currentHost = Self.lab
        #expect(Set(model.spacesSections.map(\.host)) == [Self.lab])
    }

    @Test("搜尋主機名稱(原 Agents 檢視的情境)：主機名稱符合時那台主機的所有段落整段保留")
    func spacesSearchMatchesHostName() async {
        let model = await AgentListHostFilterTests.loadedModel()
        let labTabs = model.spacesSections.filter { $0.host == Self.lab }.flatMap(\.tabs).count

        model.query = "lab"

        let sections = model.spacesSections
        #expect(!sections.isEmpty)
        #expect(sections.allSatisfy { $0.host == Self.lab })
        #expect(sections.flatMap(\.tabs).count == labTabs, "主機名稱符合時段內的 Tab 不被濾掉")
    }

    @Test("搜尋 Agent 標題(原 Agents 檢視的情境)：Tab 取了名稱、標題不是 Agent 標題時，Agent 標題仍找得到那個 Tab")
    func spacesSearchMatchesAgentTitleInsideNamedTab() async throws {
        let model = await AgentListHostFilterTests.loadedModel { response in
            SnapshotEdit.tab("w1:tA", in: &response) { $0["label"] = "CSV 匯出" }
        }
        let tab = try #require(model.spacesSections.first?.tabs.first { $0.title == "CSV 匯出" })
        let agentTitle = try #require(tab.searchTerms.first { $0 != "CSV 匯出" })

        model.query = agentTitle

        #expect(model.spacesSections.flatMap(\.tabs).contains { $0.id == tab.id })
    }

    @Test("沒有 Agents／Spaces 切換:沒有檢視模式可選，列表永遠訂閱版面事件、內容是 Spaces")
    func listIsAlwaysSpaces() async {
        let model = await AgentListHostFilterTests.loadedModel()

        #expect(model.list(for: Self.studio)?.subscribesToLayout == true)
        #expect(model.content == .list)
    }
}
