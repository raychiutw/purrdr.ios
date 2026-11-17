import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Spaces 檢視的「已釘選」、各組數量與未讀(#40 與 #41 合併;行為規格 F2.2、F2.5、F2.6)。
///
/// 以錄製 snapshot 為底，把 `w1:pB` 移到只有它的 workspace `w9`(單一 Agent → 聊天列);
/// `w1`(garden-journal)剩 `w1:p6`(idle)與 `w1:pA`(working)兩個 Agent → workspace 卡片。
@MainActor
@Suite("Spaces 檢視的已釘選與未讀")
struct SpacesPinnedTests {
    static let studio = UnreadPinnedTests.studio
    static let t0 = UnreadPinnedTests.t0

    static func studioHost(clock: MarkerClock) async -> UnreadPinnedTests.Host {
        await UnreadPinnedTests.host(studio, clock: clock, snapshots: [{
            SnapshotEdit.agent("w1:pB", in: &$0) { $0["workspace_id"] = "w9" }
        }])
    }

    static func id(_ local: String) -> String { "\(studio.storedValue)/\(local)" }

    static func card(_ workspaceID: String, in model: MergedAgentListModel) -> WorkspaceGroup? {
        model.spacesSections.flatMap(\.items).lazy.compactMap { item -> WorkspaceGroup? in
            if case .group(let group) = item, group.workspaceID == workspaceID { group } else { nil }
        }.first
    }

    static func cardRow(_ paneID: String, in card: WorkspaceGroup?) -> AgentRow? {
        card?.rows.lazy.compactMap { row -> AgentRow? in
            if case .agent(let agent) = row, agent.paneID == paneID { agent } else { nil }
        }.first
    }

    @Test("有任一 Agent 被釘選的卡片、被釘選的聊天列排進已釘選，依釘選時間舊→新;卡片不再出現在別組")
    func pinnedCardAndChatOrderedByPinTime() async throws {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.studioHost(clock: clock)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()

        // 先釘 w9 的聊天列，再釘卡片裡的 Agent(依 workspace 順序卡片會在前，依釘選時間則聊天列在前)。
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionB)
        clock.now = Self.t0.addingTimeInterval(10)
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionA)

        // 只有 shell 的 `w2`(scratch)沒有 Agent 可釘，留在主機組。
        let sections = model.spacesSections
        #expect(sections.map(\.id) == ["pinned", Self.studio.storedValue])
        let pinned = try #require(sections.first)
        #expect(pinned.items.map(\.id) == [Self.id("w1:pB"), Self.id("w1")])
        #expect(sections.last?.items.map(\.id) == [Self.id("w2")])
    }

    @Test("卡片的釘選時間以最早釘的 Agent 為準：再釘卡片裡另一個 Agent 不改變順序")
    func cardPinTimeIsEarliestPinnedAgent() async throws {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.studioHost(clock: clock)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()

        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionA)
        clock.now = Self.t0.addingTimeInterval(10)
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionB)
        clock.now = Self.t0.addingTimeInterval(20)
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionP6)

        let pinned = try #require(model.spacesSections.first)
        #expect(pinned.kind == .pinned)
        #expect(pinned.items.map(\.id) == [Self.id("w1"), Self.id("w1:pB")])
    }

    @Test("已釘選的項目不在主機組再出現一次")
    func sectionCountIsItemCount() async throws {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.studioHost(clock: clock)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()

        // 三個 Agent 都釘選：已釘選組有一張卡片(兩個 Agent)和一個聊天列 = 2 項。
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionP6)
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionA)
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionB)

        let pinned = try #require(model.spacesSections.first { $0.kind == .pinned })
        #expect(pinned.items.count == 2)
        // 主機組只剩只有 shell 的 `w2`。
        #expect(model.spacesSections.map(\.items.count) == [2, 1])
    }

    @Test("卡片裡的 Agent 列帶各自的未讀;開著的聊天不算未讀")
    func cardRowsCarryTheirOwnUnread() async throws {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.studioHost(clock: clock)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()
        model.chatAppeared(ChatRoute(host: Self.studio, paneID: "w1:p6"))
        studio.source.list.previews = [
            "w1:p6": UnreadPinnedTests.preview(Self.t0.addingTimeInterval(60)),
            "w1:pA": UnreadPinnedTests.preview(Self.t0.addingTimeInterval(60)),
        ]

        let card = Self.card("w1", in: model)
        #expect(Self.cardRow("w1:pA", in: card)?.isUnread == true)
        #expect(Self.cardRow("w1:p6", in: card)?.isUnread == false, "開著的聊天不算未讀")
        #expect(Self.cardRow("w1:p6", in: card)?.status == .idle)
    }
}

extension SpacesPinnedTests {
    @Test("已釘選組不分主機：聊天列第三行以主機名開頭、群組帶主機名;主機組裡的項目不帶")
    func pinnedItemsNameTheirHost() async throws {
        let clock = MarkerClock(Self.t0)
        let studio = await Self.studioHost(clock: clock)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()
        #expect(Self.card("w1", in: model)?.hostName == nil)

        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionB)
        studio.source.actions.togglePin(sessionID: UnreadPinnedTests.sessionA)

        let pinned = try #require(model.spacesSections.first { $0.kind == .pinned })
        guard case .chat(let chat)? = pinned.items.first, case .group(let group)? = pinned.items.last else {
            Issue.record("已釘選組應該是一個聊天列加一個群組:\(pinned.items.map(\.id))")
            return
        }
        #expect(chat.subtitle.hasPrefix("Studio · "), "聊天列第三行:\(chat.subtitle)")
        #expect(chat.hostLabel?.name == "Studio")
        #expect(group.hostName == "Studio")
    }
}
