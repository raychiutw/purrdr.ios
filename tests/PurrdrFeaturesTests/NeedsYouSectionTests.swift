import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天列表最上面的「需要你」段落與「剛剛」(#531):內容、排序(新的在前)、搜尋、沒有時不顯示、仍留在原本段落。
///
/// 錄製的 snapshot:`w1:p6`(tab t6)idle,`w1:pA`(tA)、`w1:pB`(tB)working;改動：pA、pB 改成需要你。
@MainActor
@Suite("聊天列表的需要你段落")
struct NeedsYouSectionTests {
    static func model(blocked: [String] = ["w1:pA", "w1:pB"]) async -> HostsModel {
        await SpacesViewTests.model { response in
            // 改動：指定的 Agent 改成需要你。
            for pane in blocked { SnapshotEdit.agent(pane, in: &response) { $0["agent_status"] = "blocked" } }
        }
    }

    /// 讓 `needsYou` 認得「誰先誰後」:依序一個個變成需要你(後面的較新)。
    static func order(_ model: HostsModel, _ panes: [String]) {
        let needsYou = model.agentList.needsYou
        needsYou.apply(.init(hosts: [.init(host: .demo, blocked: [])], current: []))
        for index in panes.indices {
            needsYou.apply(.init(
                hosts: [.init(host: .demo, blocked: panes[...index].map { .init(paneID: $0, isMuted: false) })], current: []))
        }
    }

    /// 驅動 `needsYou`(正式 app 由 `run` 驅動):段落只列 `others`(排除靜音與目前開著的)。
    static func drive(_ model: HostsModel, _ panes: [String], muted: Set<String> = [], current: Set<ChatRoute> = []) {
        model.agentList.needsYou.apply(.init(
            hosts: [.init(host: .demo, blocked: panes.map { .init(paneID: $0, isMuted: muted.contains($0)) })], current: current))
    }

    @Test("靜音的聊天不列進段落")
    func mutedChatsAreExcluded() async throws {
        let model = await Self.model()
        Self.drive(model, ["w1:pA", "w1:pB"], muted: ["w1:pA"])

        let section = try #require(model.agentList.needsYouSection)

        #expect(section.rows.map(\.tab.key) == ["w1:tB"])
    }

    @Test("目前開著的聊天(iPad 寬視窗)不列進段落;只剩它時整段不顯示")
    func currentChatIsExcluded() async throws {
        let model = await Self.model()
        Self.drive(model, ["w1:pA", "w1:pB"], current: [ChatRoute(host: .demo, paneID: "w1:pA")])
        #expect(model.agentList.needsYouSection?.rows.map(\.tab.key) == ["w1:tB"])

        Self.drive(model, ["w1:pA"], current: [ChatRoute(host: .demo, paneID: "w1:pA")])
        #expect(model.agentList.needsYouSection == nil)
    }

    @Test("內容:需要你的聊天各一列(Tab 列)")
    func listsBlockedChats() async throws {
        let model = await Self.model()
        Self.drive(model, ["w1:pA", "w1:pB"])

        let section = try #require(model.agentList.needsYouSection)

        #expect(section.rows.count == 2)
        #expect(Set(section.rows.map(\.tab.key)) == ["w1:tA", "w1:tB"])
    }

    @Test("沒有需要你的聊天時整段不顯示")
    func hiddenWhenNoneBlocked() async {
        let model = await Self.model(blocked: [])

        #expect(model.agentList.needsYouSection == nil)
    }

    @Test("排序:新變成需要你的在前")
    func newestFirst() async throws {
        let model = await Self.model()
        Self.order(model, ["w1:pA", "w1:pB"])

        let section = try #require(model.agentList.needsYouSection)

        #expect(section.rows.map(\.tab.key) == ["w1:tB", "w1:tA"])
    }

    @Test("「剛剛」:只有最新轉變成需要你的那一列")
    func justNowIsLatestTransition() async throws {
        let model = await Self.model()
        Self.order(model, ["w1:pA", "w1:pB"])

        let section = try #require(model.agentList.needsYouSection)

        #expect(section.rows.map(\.isJustNow) == [true, false])
    }

    @Test("「剛剛」:一開始就需要你的(不是看著它轉變的)沒有標記")
    func noJustNowWithoutTransition() async throws {
        let model = await Self.model()
        model.agentList.needsYou.apply(.init(
            hosts: [.init(host: .demo, blocked: [.init(paneID: "w1:pA", isMuted: false), .init(paneID: "w1:pB", isMuted: false)])],
            current: []))

        let section = try #require(model.agentList.needsYouSection)

        #expect(section.rows.allSatisfy { !$0.isJustNow })
    }

    @Test("這些列仍留在原本的「主機 · Workspace」段落")
    func rowsStayInWorkspaceSections() async throws {
        let model = await Self.model()
        Self.drive(model, ["w1:pA", "w1:pB"])

        _ = try #require(model.agentList.needsYouSection)

        let keys = model.agentList.spacesSections.flatMap(\.tabs).map(\.key)
        #expect(keys.contains("w1:tA") && keys.contains("w1:tB"))
    }

    @Test("搜尋時這段也套用搜尋;都不符合就不顯示")
    func searchAppliesToSection() async throws {
        let model = await Self.model()
        Self.drive(model, ["w1:pA", "w1:pB"])
        let target = try #require(model.agentList.needsYouSection?.rows.first { $0.tab.key == "w1:tB" }?.tab)

        model.agentList.query = try #require(target.searchTerms.first)
        #expect(model.agentList.needsYouSection?.rows.map(\.tab.key) == ["w1:tB"])

        model.agentList.query = "查無此聊天 zzz"
        #expect(model.agentList.needsYouSection == nil)
    }

    @Test("不受主機篩選影響:所有主機需要你的都列")
    func ignoresHostFilter() async throws {
        let model = await Self.model()
        Self.drive(model, ["w1:pA", "w1:pB"])
        model.agentList.currentHost = .host(UUID())

        #expect(model.agentList.needsYouSection?.rows.count == 2)
    }

    @Test("標題帶數量;「剛剛」有固定文字(畫面與 VoiceOver 共用)")
    func texts() {
        #expect(NeedsYouSection.title(count: 2).contains("2"))
        #expect(NeedsYouSection.justNowText == String(localized: "Just now"))
    }
}
