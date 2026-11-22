import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 用量區(#389):面板與主機 tab 共用。已用／剩餘是全域設定,同時套用到 5 小時、7 天與 context。
@MainActor
@Suite("用量區")
struct UsageSectionModelTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    static func usage(
        fiveHourUsed: Double = 38, weekUsed: Double = 74, fiveHourResets: TimeInterval = 3_600, weekResets: TimeInterval = 86_400,
        capturedAgo: TimeInterval = 30
    ) -> PlanUsage {
        PlanUsage(
            periods: [
                .init(kind: .fiveHour, usedPercentage: fiveHourUsed, resetsAt: now.addingTimeInterval(fiveHourResets)),
                .init(kind: .week, usedPercentage: weekUsed, resetsAt: now.addingTimeInterval(weekResets)),
            ], capturedAt: now.addingTimeInterval(-capturedAgo))
    }

    static func source(_ usage: PlanUsage?, granted: Bool? = nil) -> PlanUsageSource {
        let write = granted.map { granted in
            PlanUsageHostWrite(isGranted: { granted }, inspect: { "ray" }, install: {}, restore: {})
        }
        return PlanUsageSource(cost: .free, hostWrite: write) { usage }
    }

    /// 這些測試的百分比以「剩餘」為準(預設已用,#420)。
    static func remainingSetting() -> UsageDisplaySetting {
        let setting = UsageDisplaySetting()
        setting.display = .remaining
        return setting
    }

    func model(
        display: UsageDisplaySetting = Self.remainingSetting(), agents: [PlanUsageAgent] = [.claudeCode],
        sources: [PlanUsageAgent: PlanUsageSource]
    ) -> UsageSectionModel {
        UsageSectionModel(
            hostName: "Ray Mac Mini", agents: agents, display: display, now: { Self.now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        ) { sources[$0] }
    }

    @Test("沒設定過時預設顯示已用;已存的「剩餘」偏好保持(#420)")
    func defaultsToUsedKeepingStoredRemaining() {
        #expect(UsageDisplaySetting().display == .used)
        let defaults = UserDefaults(suiteName: "usage-default-\(UUID())")!
        #expect(UsageDisplaySetting(defaults: defaults).display == .used)
        PlanUsageModel.Display.remaining.store(in: defaults)
        #expect(UsageDisplaySetting(defaults: defaults).display == .remaining)
    }

    @Test("已用／剩餘跨重啟保存")
    func displayPersists() {
        let suite = "usage-persist-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UsageDisplaySetting(defaults: defaults).display = .remaining
        #expect(UsageDisplaySetting(defaults: UserDefaults(suiteName: suite)!).display == .remaining)
        // 與設定 tab、方案用量頁讀同一個 key。
        #expect(PlanUsageModel.Display.stored(in: defaults) == .remaining)
    }

    @Test("切換已用／剩餘同時套用到 5 小時、7 天與 context")
    func displayAppliesToEveryNumber() async {
        let setting = UsageDisplaySetting()
        let model = model(display: setting, sources: [.claudeCode: Self.source(Self.usage())])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries[0].rows.map(\.percent) == [38, 74])
        #expect(setting.shownPercent(forUsed: 18) == 18)
        setting.display = .remaining
        #expect(model.entries[0].rows.map(\.percent) == [62, 26])
        #expect(setting.shownPercent(forUsed: 18) == 82)
        model.disappeared()
    }

    @Test("過了重設時間的視窗不顯示;全部過期時當作沒有資料")
    func expiredWindowsAreHidden() async {
        let model = model(sources: [.claudeCode: Self.source(Self.usage(fiveHourResets: -1))])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries[0].rows.map(\.period) == [.week])
        model.disappeared()

        let allExpired = self.model(sources: [.claudeCode: Self.source(Self.usage(fiveHourResets: -1, weekResets: -5))])
        allExpired.appeared()
        await allExpired.untilIdle()
        #expect(allExpired.entries[0].state == .noData)
        allExpired.disappeared()
    }

    @Test("資料超過 10 分鐘標「N 分鐘前」,10 分鐘內不標")
    func staleMinutes() async {
        let fresh = model(sources: [.claudeCode: Self.source(Self.usage(capturedAgo: 600))])
        fresh.appeared()
        await fresh.untilIdle()
        #expect(fresh.entries[0].staleMinutes == nil)
        fresh.disappeared()

        let stale = model(sources: [.claudeCode: Self.source(Self.usage(capturedAgo: 12 * 60 + 20))])
        stale.appeared()
        await stale.untilIdle()
        #expect(stale.entries[0].staleMinutes == 12)
        stale.disappeared()
    }

    @Test("主機尚未同意包裝腳本時顯示「啟用用量顯示」,不讀取")
    func needsEnableWhenNotGranted() async {
        let model = model(sources: [.claudeCode: Self.source(Self.usage(), granted: false)])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries[0].state == .needsEnable)
        #expect(model.entries[0].rows.isEmpty)
        model.disappeared()
    }

    @Test("同意後顯示用量")
    func grantedShowsRows() async {
        let model = model(sources: [.claudeCode: Self.source(Self.usage(), granted: true)])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries[0].rows.count == 2)
        model.disappeared()
    }

    @Test("HTTPS 主機沒有用量來源:整區是「等主機服務支援」,不是壞畫面")
    func httpsIsUnsupported() async {
        let model = model(agents: [.claudeCode, .codex], sources: [:])
        model.appeared()
        await model.untilIdle()
        #expect(model.isUnsupported)
        #expect(model.entries.isEmpty)
        model.disappeared()
    }

    @Test("先讀到、之後讀不到(主機離線):保留最後讀到的資料,並標示是最後的資料(#392)")
    func keepsLastDataWhenHostGoesOffline() async {
        struct Offline: Error {}
        let calls = CallCounter()
        let usage = Self.usage()
        let flaky = PlanUsageSource(cost: .free) {
            if calls.next() == 1 { return usage }
            throw Offline()
        }
        let model = model(sources: [.claudeCode: flaky])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries[0].state == .rows)
        #expect(!model.isShowingLastKnownData)

        await model.refresh()

        #expect(model.entries[0].state == .rows)
        #expect(model.entries[0].rows.map(\.percent) == [62, 26])
        #expect(model.isShowingLastKnownData)
        #expect(model.lastCapturedAt == usage.capturedAt)
        model.disappeared()
    }

    @Test("從來沒讀到過就讀不到:仍是失敗,不是最後的資料")
    func failureWithoutEarlierDataIsAFailure() async {
        struct Offline: Error {}
        let model = model(sources: [.claudeCode: PlanUsageSource(cost: .free) { throw Offline() }])
        model.appeared()
        await model.untilIdle()
        guard case .failed = model.entries[0].state else {
            Issue.record("應該是失敗")
            return
        }
        #expect(!model.isShowingLastKnownData)
        model.disappeared()
    }

    @Test("主機 tab 同時列 Claude 與 Codex,各自的狀態互不影響")
    func twoAgentsAreIndependent() async {
        let model = model(
            agents: [.claudeCode, .codex],
            sources: [.claudeCode: Self.source(Self.usage(), granted: false), .codex: Self.source(Self.usage(fiveHourUsed: 12, weekUsed: 90))])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries.map(\.agent) == [.claudeCode, .codex])
        #expect(model.entries[0].state == .needsEnable)
        #expect(model.entries[1].rows.map(\.percent) == [88, 10])
        model.disappeared()
    }

    @Test("讀取失敗時只有那個 Agent 顯示失敗")
    func failureIsPerAgent() async {
        struct Boom: Error {}
        let failing = PlanUsageSource(cost: .free) { throw Boom() }
        let model = model(agents: [.claudeCode, .codex], sources: [.claudeCode: Self.source(Self.usage()), .codex: failing])
        model.appeared()
        await model.untilIdle()
        #expect(model.entries[0].rows.count == 2)
        guard case .failed = model.entries[1].state else {
            Issue.record("Codex 應該是失敗")
            return
        }
        model.disappeared()
    }
}

@Suite("用量等級與警示")
struct UsageLevelTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    func row(used: Double) -> PlanUsageRow {
        let usage = PlanUsage(periods: [.init(kind: .fiveHour, usedPercentage: used, resetsAt: nil)], capturedAt: Self.now)
        return PlanUsagePresentation.rows(for: usage, showing: .used, now: Self.now)[0]
    }

    @Test("已用 70% 起偏高、85% 起將用完,其餘正常;與顯示已用或剩餘無關")
    func levelFollowsUsed() {
        #expect(row(used: 69).level == .ample)
        #expect(row(used: 70).level == .low)
        #expect(row(used: 84).level == .low)
        #expect(row(used: 85).level == .depleted)
        let usage = PlanUsage(periods: [.init(kind: .week, usedPercentage: 74, resetsAt: nil)], capturedAt: Self.now)
        #expect(PlanUsagePresentation.rows(for: usage, showing: .remaining, now: Self.now)[0].level == .low)
    }

    @Test("到門檻加警示三角,不只靠顏色")
    func warningFromThreshold() {
        #expect(!row(used: 69).showsWarning)
        #expect(row(used: 70).showsWarning)
        #expect(row(used: 100).showsWarning)
    }
}

/// 測試用的執行緒安全計數。
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
