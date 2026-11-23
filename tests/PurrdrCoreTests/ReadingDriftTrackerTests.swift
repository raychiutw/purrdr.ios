import Foundation
import PurrdrCore
import Testing

/// 閱讀位置位移追蹤(#489 驗收用除錯量測)。
@Suite("閱讀位置位移追蹤")
struct ReadingDriftTrackerTests {
    @Test("沒有基準時不累計")
    func noBaselineRecordsNothing() {
        var tracker = ReadingDriftTracker()
        tracker.observe(distanceFromVisibleTop: 40)
        #expect(tracker.maxDrift == 0)
    }

    @Test("累計與基準的最大位移,不看方向")
    func recordsLargestDriftInEitherDirection() {
        var tracker = ReadingDriftTracker()
        tracker.setBaseline(rowID: "r1", distanceFromVisibleTop: 100)
        tracker.observe(distanceFromVisibleTop: 100)
        tracker.observe(distanceFromVisibleTop: 130)
        tracker.observe(distanceFromVisibleTop: 90)
        #expect(tracker.maxDrift == 30)
        #expect(tracker.baselineRowID == "r1")
    }

    @Test("重設基準會清掉先前的最大位移")
    func newBaselineClearsMaxDrift() {
        var tracker = ReadingDriftTracker()
        tracker.setBaseline(rowID: "r1", distanceFromVisibleTop: 100)
        tracker.observe(distanceFromVisibleTop: 160)
        tracker.setBaseline(rowID: "r2", distanceFromVisibleTop: 10)
        #expect(tracker.maxDrift == 0)
        #expect(tracker.baselineRowID == "r2")
    }

    @Test("清除基準後停止累計")
    func clearStopsTracking() {
        var tracker = ReadingDriftTracker()
        tracker.setBaseline(rowID: "r1", distanceFromVisibleTop: 100)
        tracker.clear()
        tracker.observe(distanceFromVisibleTop: 500)
        #expect(tracker.maxDrift == 0)
        #expect(tracker.baselineRowID == nil)
    }
}
