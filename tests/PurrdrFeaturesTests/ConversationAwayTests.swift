import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 聊天裡的離開期間分隔線(#308)。
@MainActor
@Suite("對話離開期間摘要")
struct ConversationAwayTests {
    @Test("離開 15 分鐘以上：分隔線定在離開後第一個項目;收合只留最後一句;開著期間定下來不再變")
    func summaryAndCollapse() async throws {
        let probe = try ConversationModelTests.setup()
        await probe.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await probe.model.poll()
        let dates = probe.model.items.compactMap(\.date)
        let first = try #require(dates.min())
        let last = try #require(dates.max())

        let fresh = try ConversationModelTests.setup()
        // 離開起點在第一則之前一小時，進來的時間在最後一則之後。
        fresh.clock.advance(by: last.timeIntervalSince(fresh.clock.now) + 60)
        var away: Date? = first.addingTimeInterval(-3600)
        fresh.model.awayStart = { away }
        await fresh.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await fresh.model.poll()

        let summary = try #require(fresh.model.awaySummary)
        #expect(summary.turns >= 1)
        #expect(summary.anchorID == fresh.model.items.first { $0.date != nil }?.id)

        let all = fresh.model.visibleEntries.count
        fresh.model.isAwayCollapsed = true
        #expect(fresh.model.visibleEntries.count < all)
        #expect(fresh.model.visibleEntries.contains { $0.id == summary.lastReplyID })

        away = nil
        await fresh.model.poll()
        #expect(fresh.model.awaySummary == summary, "定下來之後不隨離開起點改變")
    }

    @Test("沒有離開起點(沒開過的聊天)：沒有摘要")
    func noAwayStart() async throws {
        let setup = try ConversationModelTests.setup()
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await setup.model.poll()
        #expect(setup.model.awaySummary == nil)
    }
}
