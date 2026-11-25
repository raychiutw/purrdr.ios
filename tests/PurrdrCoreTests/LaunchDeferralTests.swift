import Foundation
import Synchronization
import Testing

@testable import PurrdrCore

/// 冷啟動的 I/O 延後(#590):流量歷史第一次需要時才讀、存檔等第一個 frame 之後。
@Suite("啟動 I/O 延後")
struct LaunchDeferralTests {
    final class CountingStore: TrafficStore {
        private let counts = Mutex((loads: 0, saves: 0))
        let days: [TrafficDay]
        init(days: [TrafficDay] = []) { self.days = days }
        func load() -> [TrafficDay] {
            counts.withLock { $0.loads += 1 }
            return days
        }
        func save(_ days: [TrafficDay]) { counts.withLock { $0.saves += 1 } }
        var loads: Int { counts.withLock { $0.loads } }
        var saves: Int { counts.withLock { $0.saves } }
    }

    @Test("建立計量時不讀存放處;第一次讀歷史才讀一次")
    func loadsHistoryLazily() {
        let today = TrafficDay(day: "2026-11-25", hosts: ["h": [.wifi: TrafficBytes(sent: 1, received: 2)]])
        let store = CountingStore(days: [today])
        let meter = TrafficMeter(store: store, now: { Date(timeIntervalSince1970: 1_795_600_000) }, calendar: Self.utc)
        #expect(store.loads == 0)
        _ = meter.sinceLaunch()
        #expect(store.loads == 0)
        _ = meter.days()
        _ = meter.days()
        #expect(store.loads == 1)
    }

    @Test("開閘前累計的流量不寫檔,開閘後才寫")
    func savesOnlyAfterGateOpens() async {
        let store = CountingStore()
        let gate = LaunchGate()
        let meter = TrafficMeter(store: store, launchGate: gate)
        meter.record(hostID: "h", direction: .sent, bytes: 10)
        _ = meter.days()  // 同步彙總,排出存檔
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.saves == 0)
        gate.open()
        for _ in 0..<100 where store.saves == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(store.saves == 1)
    }

    @Test("閘沒開時進背景仍立刻存")
    func backgroundFlushIgnoresGate() async {
        let store = CountingStore()
        let meter = TrafficMeter(store: store, launchGate: LaunchGate())
        meter.record(hostID: "h", direction: .sent, bytes: 10)
        await withCheckedContinuation { continuation in meter.flushInBackground { continuation.resume() } }
        #expect(store.saves == 1)
    }

    @Test("LaunchGate 開閘前登記、開閘後立刻執行、只開一次")
    func gateRunsWorkOnce() {
        let gate = LaunchGate()
        let ran = Mutex(0)
        gate.run { ran.withLock { $0 += 1 } }
        #expect(ran.withLock { $0 } == 0)
        gate.open()
        gate.open()
        #expect(ran.withLock { $0 } == 1)
        gate.run { ran.withLock { $0 += 1 } }
        #expect(ran.withLock { $0 } == 2)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
