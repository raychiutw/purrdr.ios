import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 聊天列表的主機篩選與單一清單(#244)。
@MainActor
@Suite("聊天列表主機篩選")
struct AgentListHostFilterTests {
    static let bridge = HerdrCommand.bridge()
    static let studio = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!)
    static let lab = HostSelection.host(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)

    static func source(_ host: HostSelection, name: String, icon: HostIcon = .default, fails: Bool = false) async -> MergedAgentListModel.Source {
        let fake = FakeHost()
        if fails {
            await fake.failConnection(with: SSHConnectionError.timedOut)
        } else {
            await fake.expect(bridge, reply: .recorded("session.snapshot.ndjson"))
        }
        let client = HerdrClient(channel: fake)
        return MergedAgentListModel.Source(
            host: host, name: name, icon: icon, list: AgentListModel(client: client, host: host),
            actions: WorkspaceActionsModel(client: client, preferences: InMemoryChatPreferencesStore()))
    }

    static func loadedModel(labFails: Bool = false) async -> MergedAgentListModel {
        let model = MergedAgentListModel()
        let sources = [
            await source(studio, name: "Studio", icon: .macMini),
            await source(lab, name: "Lab", icon: .rack, fails: labFails),
        ]
        model.update(sources: sources, selected: studio)
        await model.load()
        return model
    }

    @Test("預設是所有主機：兩台主機的列都在")
    func defaultShowsAllHosts() async {
        let model = await Self.loadedModel()

        #expect(model.hostFilter == nil)
        #expect(model.sections.flatMap(\.rows).count == 6)
    }

    @Test("篩選某台主機：Agents 與 Spaces 都只剩那台主機的列")
    func filterLimitsAgentsAndSpaces() async {
        let model = await Self.loadedModel()

        model.hostFilter = Self.lab

        let rows = model.sections.flatMap(\.rows)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.host == Self.lab })
        #expect(model.spacesSections.compactMap(\.host?.host) == [Self.lab])
    }

    @Test("篩選某台主機時，其他主機的連線錯誤不出現在列表下方")
    func filterHidesOtherHostsFailures() async {
        let model = await Self.loadedModel(labFails: true)
        #expect(model.failures.map(\.host) == [Self.lab])

        model.hostFilter = Self.studio

        #expect(model.failures.isEmpty)
    }

    @Test("篩選選單：每台主機一項，帶名稱與主機圖示，依列表的主機順序")
    func filterOptionsListHostsWithIcons() async {
        let model = await Self.loadedModel()

        #expect(model.hostFilterOptions == [
            HostLabelOption(host: Self.studio, label: HostLabel(name: "Studio", icon: .macMini)),
            HostLabelOption(host: Self.lab, label: HostLabel(name: "Lab", icon: .rack)),
        ])
    }

    @Test("篩選選某台主機：同時設成選取中主機")
    func filteringHostSelectsIt() async {
        let model = await Self.loadedModel()
        var selected: [HostSelection] = []
        model.selectHost = { selected.append($0) }

        model.hostFilter = Self.lab

        #expect(selected == [Self.lab])
    }

    @Test("篩選選回所有主機：選取中主機不變")
    func filteringAllHostsKeepsSelection() async {
        let model = await Self.loadedModel()
        model.hostFilter = Self.lab
        var selected: [HostSelection] = []
        model.selectHost = { selected.append($0) }

        model.hostFilter = nil

        #expect(selected.isEmpty)
    }

    @Test("篩選中的主機被刪除：回到所有主機")
    func removedFilteredHostFallsBackToAll() async {
        let model = await Self.loadedModel()
        model.hostFilter = Self.lab

        model.update(sources: [await Self.source(Self.studio, name: "Studio")], selected: Self.studio)

        #expect(model.hostFilter == nil)
    }

    @Test("單一清單：所有列依「已釘選／需要你／工作中／閒置」的順序排成一份")
    func singleListKeepsGroupOrder() async {
        let model = await Self.loadedModel()

        let expected = model.sections.flatMap(\.rows).map(\.id)
        #expect(model.agentRows.map(\.id) == expected)
        #expect(model.agentRows.first?.status == .working, "工作中的列應在閒置之前")
    }

    @Test("每一列都查得到主機名稱與圖示，選取中主機也是(預覽「主機 · 最後一句」用)")
    func everyRowHasHostLabel() async {
        let model = await Self.loadedModel()

        #expect(model.hostLabel(of: Self.studio) == HostLabel(name: "Studio", icon: .macMini))
        #expect(model.hostLabel(of: Self.lab) == HostLabel(name: "Lab", icon: .rack))
    }
}
