import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天 tab 左上角的 Agents／Spaces 一鍵切換與搜尋(#391)。
@MainActor
@Suite("聊天 tab 切換檢視與搜尋")
struct ChatsSwitchSearchTests {
    static let studio = AgentListHostFilterTests.studio
    static let lab = AgentListHostFilterTests.lab

    @Test("一鍵切換：Agents 與 Spaces 互換，並記住")
    func toggleModeSwitchesAndRemembers() {
        let store = InMemoryAgentListModeStore(.agents)
        let model = MergedAgentListModel(modeStore: store)

        model.toggleMode()
        #expect(model.mode == .spaces)
        #expect(store.load() == .spaces)

        model.toggleMode()
        #expect(model.mode == .agents)
        #expect(store.load() == .agents)
    }

    @Test("Spaces 檢視搜尋 workspace 名稱：符合的 workspace 整段保留，其他段落不出現")
    func spacesSearchMatchesWorkspaceName() async {
        let model = await AgentListHostFilterTests.loadedModel()
        model.mode = .spaces

        model.query = "garden"

        let sections = model.spacesSections
        #expect(!sections.isEmpty)
        #expect(sections.allSatisfy { $0.workspace == "garden-journal" })
        #expect(sections.allSatisfy { $0.tabs.count == 3 }, "workspace 名稱符合時段內的 Tab 不被濾掉")
    }

    @Test("Spaces 檢視搜尋 Tab 名稱：只留符合的 Tab，沒有符合 Tab 的段落不出現")
    func spacesSearchMatchesTabTitle() async {
        let model = await AgentListHostFilterTests.loadedModel()
        model.mode = .spaces

        model.query = "食譜"

        let sections = model.spacesSections
        #expect(!sections.isEmpty)
        #expect(sections.flatMap(\.tabs).allSatisfy { $0.title.contains("食譜") })
        #expect(sections.flatMap(\.tabs).count == 2, "兩台主機各一個符合的 Tab")
    }

    @Test("Spaces 檢視搜尋找不到：沒有任何段落;清掉搜尋回到全部")
    func spacesSearchWithoutMatchAndCleared() async {
        let model = await AgentListHostFilterTests.loadedModel()
        model.mode = .spaces
        let all = model.spacesSections

        model.query = "zzz-沒有這個"
        #expect(model.spacesSections.isEmpty)

        model.query = "  "
        #expect(model.spacesSections == all)
    }

    @Test("搜尋範圍是目前主機：選某台只搜那台，所有主機搜全部(Agents 與 Spaces)")
    func searchScopeFollowsCurrentHost() async {
        let model = await AgentListHostFilterTests.loadedModel()

        model.query = "garden"
        model.mode = .spaces
        #expect(Set(model.spacesSections.map(\.host)) == [Self.studio, Self.lab])
        model.mode = .agents
        #expect(Set(model.sections.flatMap(\.rows).map(\.host)) == [Self.studio, Self.lab])

        model.currentHost = Self.lab
        #expect(Set(model.sections.flatMap(\.rows).map(\.host)) == [Self.lab])
        model.mode = .spaces
        #expect(Set(model.spacesSections.map(\.host)) == [Self.lab])
    }

    @Test("切換檢視不清掉搜尋字串：兩種檢視共用同一個搜尋")
    func queryIsSharedAcrossModes() async {
        let model = await AgentListHostFilterTests.loadedModel()
        model.query = "garden"

        model.toggleMode()

        #expect(model.query == "garden")
    }
}
