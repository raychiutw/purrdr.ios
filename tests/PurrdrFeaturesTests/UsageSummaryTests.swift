import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 聊天頂列用量環的摘要(#513):context、目前工作階段、每週取「已用」最高的一項,等級沿用 context 門檻,
/// 數字跟著「已用／剩餘」設定。
@Suite("用量摘要")
struct UsageSummaryTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    static func rows(fiveHourUsed: Double? = nil, weekUsed: Double? = nil, display: PlanUsageModel.Display = .used) -> [PlanUsageRow] {
        var periods: [PlanUsage.Period] = []
        if let fiveHourUsed {
            periods.append(.init(kind: .fiveHour, usedPercentage: fiveHourUsed, resetsAt: now.addingTimeInterval(3_600)))
        }
        if let weekUsed {
            periods.append(.init(kind: .week, usedPercentage: weekUsed, resetsAt: now.addingTimeInterval(86_400)))
        }
        return PlanUsagePresentation.rows(for: PlanUsage(periods: periods, capturedAt: now), showing: display, now: now)
    }

    @Test("三項取最高的一項")
    func picksHighest() {
        let summary = UsageSummary.make(contextUsed: 21, planRows: Self.rows(fiveHourUsed: 12, weekUsed: 93), display: .used)
        #expect(summary?.source == .weekly)
        #expect(summary?.percent == 93)
        let context = UsageSummary.make(contextUsed: 60, planRows: Self.rows(fiveHourUsed: 12, weekUsed: 30), display: .used)
        #expect(context?.source == .context)
        let session = UsageSummary.make(contextUsed: 10, planRows: Self.rows(fiveHourUsed: 55, weekUsed: 30), display: .used)
        #expect(session?.source == .currentSession)
    }

    @Test("同樣高時優先每週、再來目前工作階段、最後 context")
    func tieBreak() {
        #expect(UsageSummary.make(contextUsed: 50, planRows: Self.rows(fiveHourUsed: 50, weekUsed: 50), display: .used)?.source == .weekly)
        #expect(UsageSummary.make(contextUsed: 50, planRows: Self.rows(fiveHourUsed: 50), display: .used)?.source == .currentSession)
    }

    @Test("門檻邊界:69 一般、70 橙、84 橙、85 紅")
    func levelBoundaries() {
        func level(_ used: Int) -> AgentProgress.ContextLevel? {
            UsageSummary.make(contextUsed: used, planRows: [], display: .used)?.level
        }
        #expect(level(69) == .normal)
        #expect(level(70) == .warning)
        #expect(level(84) == .warning)
        #expect(level(85) == .critical)
    }

    @Test("沒有方案用量時只看 context;都沒有時沒有用量環")
    func contextOnlyOrNothing() {
        let summary = UsageSummary.make(contextUsed: 18, planRows: [], display: .used)
        #expect(summary?.source == .context)
        #expect(summary?.percent == 18)
        #expect(UsageSummary.make(contextUsed: nil, planRows: [], display: .used) == nil)
    }

    @Test("沒有 context 時只看方案用量")
    func planOnly() {
        let summary = UsageSummary.make(contextUsed: nil, planRows: Self.rows(weekUsed: 40), display: .used)
        #expect(summary?.source == .weekly)
    }

    @Test("剩餘設定:數字換算、仍以已用挑最高與分級")
    func remainingDisplay() {
        let rows = Self.rows(fiveHourUsed: 12, weekUsed: 93, display: .remaining)
        let summary = UsageSummary.make(contextUsed: 21, planRows: rows, display: .remaining)
        #expect(summary?.source == .weekly)
        #expect(summary?.percent == 7)
        #expect(summary?.level == .critical)
        let context = UsageSummary.make(contextUsed: 82, planRows: [], display: .remaining)
        #expect(context?.percent == 18)
        #expect(context?.level == .warning)
    }

    @Test("VoiceOver 句子")
    func accessibilitySentence() {
        let used = UsageSummary.make(contextUsed: 21, planRows: Self.rows(weekUsed: 93), display: .used)
        #expect(used?.accessibilityText == "Usage: Weekly 93%")
        let left = UsageSummary.make(contextUsed: 21, planRows: Self.rows(weekUsed: 93, display: .remaining), display: .remaining)
        #expect(left?.accessibilityText == "Usage: Weekly 7% left")
        let context = UsageSummary.make(contextUsed: 21, planRows: [], display: .used)
        #expect(context?.accessibilityText == "Usage: Context 21%")
    }
}
