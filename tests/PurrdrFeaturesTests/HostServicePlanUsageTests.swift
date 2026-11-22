import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// HTTPS 主機的方案用量(主機服務 0.12.0 起,#392):`usage.*` 的結果換成與 SSH 相同的 `PlanUsage`。
@Suite("HTTPS 主機的方案用量")
struct HostServicePlanUsageTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    @Test("週期種類、已用比例與重設時間對應到方案用量")
    func mapsPeriods() throws {
        let periods: [HostServiceProtocol.PlanUsagePeriod] = [
            .init(kind: .fiveHour, usedPercentage: 38, resetsAt: "2026-11-22T14:00:00Z"),
            .init(kind: .week, usedPercentage: 74.5),
        ]
        let usage = try #require(PlanUsage(hostServicePeriods: periods, capturedAt: "2026-11-22T12:00:00Z", now: Self.now))
        #expect(usage.periods.map(\.kind) == [.fiveHour, .week])
        #expect(usage.periods.map(\.usedPercentage) == [38, 74.5])
        #expect(usage.periods[0].resetsAt == Date(timeIntervalSince1970: 1_795_356_000))
        #expect(usage.periods[1].resetsAt == nil)
        #expect(usage.capturedAt == Date(timeIntervalSince1970: 1_795_348_800))
    }

    @Test("沒有擷取時間時用現在;沒有任何週期是沒有資料")
    func missingCapturedAtAndEmptyPeriods() throws {
        let one: [HostServiceProtocol.PlanUsagePeriod] = [.init(kind: .week, usedPercentage: 10)]
        #expect(PlanUsage(hostServicePeriods: one, capturedAt: nil, now: Self.now)?.capturedAt == Self.now)
        #expect(PlanUsage(hostServicePeriods: [], capturedAt: "2026-11-22T12:00:00Z", now: Self.now) == nil)
    }
}
