import Foundation
import PurrdrCore
import Testing

/// 數據用量的流量計量(#353):依主機 × 網路類型 × 方向累計，按日(本地時區)存 30 天。
@Suite("流量計量")
struct TrafficMeterTests {
    /// 手動撥的時鐘，時區固定 UTC+8(台灣)，跨日以本地午夜為界。
    final class Clock: @unchecked Sendable {
        var now: Date
        let calendar: Calendar
        init(_ iso: String) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
            self.calendar = calendar
            now = ISO8601DateFormatter().date(from: iso)!
        }
        func advance(days: Int) { now = now.addingTimeInterval(Double(days) * 86400) }
    }

    private func meter(_ clock: Clock, store: any TrafficStore = InMemoryTrafficStore(), network: TrafficNetwork = .wifi) -> TrafficMeter {
        TrafficMeter(store: store, now: { clock.now }, calendar: clock.calendar, network: network)
    }

    @Test("依主機、網路類型與方向累計，今天與這次開啟都看得到")
    func accumulatesByHostNetworkAndDirection() {
        let clock = Clock("2026-11-21T10:00:00+08:00")
        let meter = meter(clock)
        meter.record(hostID: "a", direction: .sent, bytes: 100)
        meter.record(hostID: "a", direction: .received, bytes: 4000)
        meter.setNetwork(.cellular)
        meter.record(hostID: "a", direction: .received, bytes: 500)
        meter.record(hostID: "b", direction: .sent, bytes: 7)

        let today = meter.today()
        #expect(today["a"]?[.wifi] == TrafficBytes(sent: 100, received: 4000))
        #expect(today["a"]?[.cellular] == TrafficBytes(sent: 0, received: 500))
        #expect(today["b"]?[.cellular] == TrafficBytes(sent: 7, received: 0))
        #expect(meter.sinceLaunch() == today)
    }

    @Test("零或負的位元組不記")
    func ignoresNonPositive() {
        let meter = meter(Clock("2026-11-21T10:00:00+08:00"))
        meter.record(hostID: "a", direction: .sent, bytes: 0)
        meter.record(hostID: "a", direction: .sent, bytes: -5)
        #expect(meter.days().isEmpty)
    }

    @Test("跨過本地午夜就記到新的一天，舊的一天保留")
    func rollsOverAtLocalMidnight() {
        let clock = Clock("2026-11-21T23:59:00+08:00")
        let meter = meter(clock)
        meter.record(hostID: "a", direction: .received, bytes: 10)
        clock.now = clock.now.addingTimeInterval(120)  // 隔天 00:01
        meter.record(hostID: "a", direction: .received, bytes: 20)

        let days = meter.days()
        #expect(days.map(\.day) == ["2026-11-21", "2026-11-22"])
        #expect(days[0].hosts["a"]?[.wifi]?.received == 10)
        #expect(days[1].hosts["a"]?[.wifi]?.received == 20)
        #expect(meter.today()["a"]?[.wifi]?.received == 20)
        #expect(meter.sinceLaunch()["a"]?[.wifi]?.received == 30)
    }

    @Test("只保留最近 30 天(含今天);更早的丟掉")
    func keepsThirtyDays() {
        let clock = Clock("2026-11-01T12:00:00+08:00")
        let meter = meter(clock)
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        clock.advance(days: 29)  // 第 30 天:第一天還在
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        #expect(meter.days().count == 2)
        clock.advance(days: 1)  // 第 31 天:第一天掉出
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        #expect(meter.days().map(\.day) == ["2026-11-30", "2026-12-01"])
    }

    @Test("只讀不寫也會丟掉過期的天")
    func readingPrunes() {
        let clock = Clock("2026-11-01T12:00:00+08:00")
        let meter = meter(clock)
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        clock.advance(days: 40)
        #expect(meter.days().isEmpty)
    }

    @Test("存到本機，重開後讀回;「這次開啟」不跟著回來")
    func persistsButLaunchIsMemoryOnly() {
        let clock = Clock("2026-11-21T10:00:00+08:00")
        let store = InMemoryTrafficStore()
        let first = meter(clock, store: store)
        first.record(hostID: "a", direction: .received, bytes: 123)
        first.flush()

        let second = meter(clock, store: store)
        #expect(second.today()["a"]?[.wifi]?.received == 123)
        #expect(second.sinceLaunch().isEmpty)
    }

    @Test("連續寫入不會每次都寫檔，間隔過了才寫;flush 一定寫")
    func throttlesSaving() {
        let clock = Clock("2026-11-21T10:00:00+08:00")
        let store = InMemoryTrafficStore()
        let meter = meter(clock, store: store)
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        #expect(store.saveCount == 1)
        clock.now = clock.now.addingTimeInterval(6)
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        #expect(store.saveCount == 2)
        meter.record(hostID: "a", direction: .sent, bytes: 1)
        meter.flush()
        #expect(store.saveCount == 3)
        #expect(store.load().first?.hosts["a"]?[.wifi]?.sent == 4)
    }

    @Test("重設清掉所有歷史與這次開啟，之後重新累計")
    func resetClearsEverything() {
        let clock = Clock("2026-11-21T10:00:00+08:00")
        let store = InMemoryTrafficStore()
        let meter = meter(clock, store: store)
        meter.record(hostID: "a", direction: .sent, bytes: 9)
        clock.advance(days: 1)
        meter.record(hostID: "a", direction: .sent, bytes: 9)

        meter.reset()
        #expect(meter.days().isEmpty)
        #expect(meter.sinceLaunch().isEmpty)
        #expect(store.load().isEmpty)
        meter.record(hostID: "a", direction: .sent, bytes: 3)
        #expect(meter.today()["a"]?[.wifi]?.sent == 3)
    }

    @Test("檔案存放:寫入再讀回相同;壞檔當作沒有資料")
    func fileStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileTrafficStore(url: url)
        #expect(store.load().isEmpty)
        let day = TrafficDay(day: "2026-11-21", hosts: ["a": [.cellular: TrafficBytes(sent: 1, received: 2)]])
        store.save([day])
        #expect(FileTrafficStore(url: url).load() == [day])
        try Data("not json".utf8).write(to: url)
        #expect(store.load().isEmpty)
    }

    @Test("用量檔排除 iCloud 備份(每次原子寫入換新檔，每次都要標)")
    func fileStoreIsExcludedFromBackup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileTrafficStore(url: url)

        store.save([TrafficDay(day: "2026-11-21")])
        store.save([TrafficDay(day: "2026-11-22")])

        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("TrafficSink 沒接計量時不記，接上後轉給計量")
    func sinkForwards() {
        let meter = meter(Clock("2026-11-21T10:00:00+08:00"))
        let sink = TrafficSink()
        sink.record(.sent, 5)
        #expect(meter.days().isEmpty)
        sink.attach(meter.recorder(for: "h"))
        sink.record(.sent, 5)
        #expect(meter.today()["h"]?[.wifi]?.sent == 5)
    }

    @Test("路徑走的介面換成網路類型:Wi-Fi 優先，其次行動網路，其餘是其他")
    func networkClassification() {
        #expect(TrafficNetwork(usesWiFi: true, usesCellular: true) == .wifi)
        #expect(TrafficNetwork(usesWiFi: false, usesCellular: true) == .cellular)
        #expect(TrafficNetwork(usesWiFi: false, usesCellular: false) == .other)
    }
}
