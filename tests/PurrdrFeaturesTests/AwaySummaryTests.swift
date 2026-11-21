import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 離開期間摘要(#308;spec #298 故事 22):離開超過 15 分鐘回來，聊天裡一條分隔線「N 輪 · 工作 M 分鐘」。
/// 主機服務沒有活動摘要訊息，由 app 依對話紀錄的時間與離開時間自己算。
@Suite("離開期間摘要")
struct AwaySummaryTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    static func user(_ id: String, _ minutes: Double) -> ConversationItem {
        .user(UserBubble(id: id, text: "請繼續", date: at(minutes), imageCount: 0))
    }
    static func reply(_ id: String, _ minutes: Double) -> ConversationItem {
        .agentText(AgentText(id: id, markdown: "做完了", date: at(minutes)))
    }

    @Test("離開 60 分鐘，期間兩輪(各 10 與 5 分鐘)：分隔線擺在離開後第一則、2 輪、工作 15 分鐘")
    func countsTurnsAndWork() {
        let items = [
            Self.user("u0", -90), Self.reply("a0", -80),
            Self.user("u1", 5), Self.reply("a1", 15),
            Self.user("u2", 30), Self.reply("a2", 35),
        ]
        let summary = AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(60))
        #expect(summary == AwaySummary(anchorID: "u1", turns: 2, workMinutes: 15, lastReplyID: "a2"))
    }

    @Test("離開不到 15 分鐘：不出現")
    func shortAwayIsHidden() {
        let items = [Self.user("u1", 2), Self.reply("a1", 8)]
        #expect(AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(14)) == nil)
    }

    @Test("剛好 15 分鐘：出現")
    func exactlyFifteenMinutes() {
        let items = [Self.user("u1", 2), Self.reply("a1", 8)]
        #expect(AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(15))?.turns == 1)
    }

    @Test("離開期間沒有任何回覆：不出現")
    func noReplyWhileAway() {
        let items = [Self.user("u0", -10), Self.reply("a0", -5)]
        #expect(AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(60)) == nil)
    }

    @Test("離開後進來才送的訊息(晚於 cutoff)不算進離開期間")
    func ignoresItemsAfterCutoff() {
        let items = [Self.user("u1", 5), Self.reply("a1", 10), Self.user("u2", 61), Self.reply("a2", 70)]
        let summary = AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(60))
        #expect(summary?.turns == 1)
        #expect(summary?.lastReplyID == "a1")
    }

    @Test("沒有使用者訊息開頭的一輪(Agent 接著先前的工作):分隔線擺在第一則離開後的項目")
    func turnWithoutUserMessage() {
        let items = [Self.reply("a1", 5), Self.reply("a2", 9)]
        let summary = AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(60))
        #expect(summary == AwaySummary(anchorID: "a1", turns: 1, workMinutes: 4, lastReplyID: "a2"))
    }

    @Test("收合：隱藏分隔線之後到最後一句之前的項目，最後一句留著")
    func collapsedHidesBetween() {
        let items = [Self.user("u1", 5), Self.reply("a1", 15), Self.user("u2", 30), Self.reply("a2", 35)]
        let summary = AwaySummary.make(items: items, awayFrom: Self.t0, cutoff: Self.at(60))!
        #expect(summary.hiddenIDs(in: items.map(\.id)) == ["u1", "a1", "u2"])
    }

    @Test("列表列的徽章：未讀且離開超過 15 分鐘才有")
    func rowBadge() {
        let opened = Self.t0
        #expect(AwaySummary.rowIsAway(isUnread: true, openedAt: opened, now: Self.at(16)))
        #expect(!AwaySummary.rowIsAway(isUnread: true, openedAt: opened, now: Self.at(14)))
        #expect(!AwaySummary.rowIsAway(isUnread: false, openedAt: opened, now: Self.at(60)))
        #expect(!AwaySummary.rowIsAway(isUnread: true, openedAt: nil, now: Self.at(60)))
    }
}

/// 列表列的「離開期間」徽章與聊天的離開起點(#308)。
@MainActor
@Suite("離開期間(列表與聊天)")
struct AwayTrackingTests {
    static let route = ChatRoute(host: UnreadPinnedTests.studio, paneID: "w1:p6")

    /// 上次離開聊天是 `leftAgo` 秒前,之後來了新回覆。
    static func model(leftAgo: TimeInterval) async -> MergedAgentListModel {
        let clock = MarkerClock(Date().addingTimeInterval(-leftAgo))
        let studio = await UnreadPinnedTests.host(UnreadPinnedTests.studio, clock: clock)
        let model = UnreadPinnedTests.merged([studio])
        await model.load()
        studio.source.list.previews = ["w1:p6": UnreadPinnedTests.preview(Date().addingTimeInterval(-leftAgo - 60))]
        model.chatAppeared(route)
        model.chatDisappeared(route)
        studio.source.list.previews = ["w1:p6": UnreadPinnedTests.preview(Date().addingTimeInterval(-10))]
        return model
    }

    @Test("離開 1 小時後有新回覆：列有離開期間徽章")
    func badgeAfterLongAway() async {
        let model = await Self.model(leftAgo: 3600)
        let row = UnreadPinnedTests.row("w1:p6", in: model)
        #expect(row?.isUnread == true)
        #expect(row?.isAway == true)
    }

    @Test("離開 5 分鐘：未讀但沒有徽章")
    func noBadgeAfterShortAway() async {
        let model = await Self.model(leftAgo: 300)
        let row = UnreadPinnedTests.row("w1:p6", in: model)
        #expect(row?.isUnread == true)
        #expect(row?.isAway == false)
    }

    @Test("離開期間徽章帶「+N 輪」:離開超過 15 分鐘的列去算輪數，同一個開啟時間只算一次(#308)")
    func badgeCountsTurns() async {
        let model = await Self.model(leftAgo: 3600)
        let counter = TurnCounter(turns: 3)
        model.awayTurnCounter = { route, openedAt in await counter.count(route, openedAt) }
        #expect(UnreadPinnedTests.row("w1:p6", in: model)?.awayTurns == nil, "還沒算")

        await model.refreshAwayTurns()
        #expect(UnreadPinnedTests.row("w1:p6", in: model)?.awayTurns == 3)

        await model.refreshAwayTurns()
        #expect(await counter.calls == 1, "沒變就不重算")
    }

    @Test("離開不到 15 分鐘的列(沒有徽章):不算輪數")
    func noCountWithoutBadge() async {
        let model = await Self.model(leftAgo: 300)
        let counter = TurnCounter(turns: 3)
        model.awayTurnCounter = { route, openedAt in await counter.count(route, openedAt) }

        await model.refreshAwayTurns()

        #expect(await counter.calls == 0)
        #expect(UnreadPinnedTests.row("w1:p6", in: model)?.awayTurns == nil)
    }

    actor TurnCounter {
        let turns: Int
        private(set) var calls = 0
        init(turns: Int) { self.turns = turns }
        func count(_ route: ChatRoute, _ openedAt: Date) -> Int? {
            calls += 1
            return turns
        }
    }

    @Test("聊天出現時記下上次離開的時間，開著期間(含自己更新的開啟時間)不變，離開後清掉")
    func awayStartIsLatchedWhileVisible() async {
        let model = await Self.model(leftAgo: 3600)
        let before = model.awayStart(for: Self.route)
        #expect(before == nil, "還沒進聊天")

        model.chatAppeared(Self.route)
        let latched = model.awayStart(for: Self.route)
        #expect(latched != nil)
        if let latched { #expect(Date().timeIntervalSince(latched) >= 3600 - 5) }

        model.chatAppeared(Self.route)
        #expect(model.awayStart(for: Self.route) == latched, "第二個視窗進來不覆蓋")

        model.chatDisappeared(Self.route)
        model.chatDisappeared(Self.route)
        #expect(model.awayStart(for: Self.route) == nil)
    }
}
