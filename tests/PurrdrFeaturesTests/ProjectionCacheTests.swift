import Foundation
@testable import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 合併列表的投影快取(#583):一次 body 讀 Spaces 段落、需要你段落與離開期間的列,只投影一次;輸入變了才重算。
@MainActor
@Suite("合併列表投影快取")
struct ProjectionCacheTests {
    @Test("一次繪製讀三份結果只投影一次")
    func oneProjectionPerRender() async {
        let model = await NeedsYouSectionTests.model()
        let list = model.agentList
        let before = list.projectionCount

        _ = list.spacesSections
        _ = list.needsYouSection
        _ = list.awayRoutes
        _ = list.spacesSections

        #expect(list.projectionCount - before == 1)
    }

    @Test("輸入沒變不重算,搜尋或需要你順序變了才重算")
    func recomputesOnlyWhenInputsChange() async {
        let model = await NeedsYouSectionTests.model()
        let list = model.agentList
        _ = list.spacesSections
        let base = list.projectionCount

        _ = list.spacesSections
        #expect(list.projectionCount == base, "相同輸入直接用快取")

        list.query = "zzz"
        _ = list.spacesSections
        #expect(list.projectionCount == base + 1, "搜尋變了要重算")
        _ = list.needsYouSection
        #expect(list.projectionCount == base + 1)

        list.query = ""
        NeedsYouSectionTests.drive(model, ["w1:pA", "w1:pB"])
        _ = list.needsYouSection
        #expect(list.projectionCount == base + 2, "需要你順序變了要重算")
        #expect(list.needsYouSection?.rows.isEmpty == false)
    }

    @Test("有主機篩選時,一次重算只算一次基礎投影(#583)")
    func filteredHostStillOneBasePass() async {
        let model = await NeedsYouSectionTests.model()
        let list = model.agentList
        let host = list.sources.first?.host
        list.currentHost = host
        let before = list.basePassCount

        _ = list.spacesSections
        _ = list.needsYouSection
        _ = list.awayRoutes

        #expect(list.basePassCount - before == 1)
    }

    @Test("離開期間門檻一到,快取立刻失效(不等下一分鐘)(#583)")
    func awayThresholdInvalidatesImmediately() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        var a = AgentListProjection.Source(host: .demo, label: nil, snapshot: nil, previews: [:])
        a.preferences.opened["s"] = opened
        var b = a
        a.now = opened.addingTimeInterval(AwaySummary.threshold - 1)
        b.now = opened.addingTimeInterval(AwaySummary.threshold)
        #expect(a != b, "跨過門檻的那一秒就要重算")
        b.now = opened.addingTimeInterval(AwaySummary.threshold - 30)
        #expect(a == b, "同一側的不同 now 不該讓快取失效")
    }

    @Test("需要你段落與 Spaces 段落的內容正確")
    func resultsAreCorrect() async {
        let model = await NeedsYouSectionTests.model()
        NeedsYouSectionTests.drive(model, ["w1:pA", "w1:pB"])
        let list = model.agentList
        #expect(list.needsYouSection?.rows.count == 2)
        #expect(list.spacesSections.flatMap(\.tabs).contains { !$0.blockedPaneIDs.isEmpty })
    }
}
