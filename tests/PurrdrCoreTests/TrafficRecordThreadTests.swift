import Foundation
import PurrdrCore
import Synchronization
import Testing

/// #470:`TrafficSink.record` 在 NIO 執行緒(iOS 非主執行緒 stack 只有 512 KB)上呼叫,
/// 日期計算、格式化與字典更新不可在呼叫端執行緒做,否則 stack 溢位閃退。
@Suite("流量計量不在呼叫端執行緒彙總")
struct TrafficRecordThreadTests {
    private final class Clock: @unchecked Sendable {
        let lock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        func advanceDay() { lock.withLock { $0 += 86400 } }
        var now: Date { lock.withLock { $0 } }
    }

    private func utcPlus8() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }

    @Test("在小 stack(64 KB)執行緒連續記錄、跨日:彙總都不在該執行緒,總量正確")
    func aggregationRunsOffTheCallingThread() async {
        let clock = Clock()
        let aggregators = Mutex<[UInt]>([])
        let meter = TrafficMeter(
            store: InMemoryTrafficStore(), now: { clock.now }, calendar: utcPlus8(), network: .wifi,
            onAggregate: { aggregators.withLock { $0.append(UInt(bitPattern: pthread_self())) } })

        let sink = TrafficSink(meter.recorder(for: "h"))
        let callerThread = Mutex<UInt?>(nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                callerThread.withLock { $0 = UInt(bitPattern: pthread_self()) }
                for day in 0..<5 {
                    for _ in 0..<1000 {
                        sink.record(.received, 10)
                        sink.record(.sent, 1)
                    }
                    if day < 4 { clock.advanceDay() }
                }
                done.resume()
            }
            thread.stackSize = 64 * 1024
            thread.start()
        }

        let caller = callerThread.withLock { $0 }
        #expect(caller != nil)
        #expect(!aggregators.withLock { $0 }.contains(caller ?? 0), "彙總不可在 record 的呼叫端執行緒執行")
        let days = meter.days()
        #expect(days.count == 5)
        #expect(days.allSatisfy { $0.hosts["h"]?[.wifi] == TrafficBytes(sent: 1000, received: 10000) })
        #expect(meter.sinceLaunch()["h"]?[.wifi] == TrafficBytes(sent: 5000, received: 50000))
    }

    @Test("TrafficMeter 原始碼不用 String(format:)(CoreFoundation 格式化吃 stack)")
    func sourceAvoidsStringFormat() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("src/PurrdrCore/TrafficMeter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("String(format:"))
    }

    @Test("日期鍵是 yyyy-MM-dd(補零)")
    func dayKeyFormat() {
        let meter = TrafficMeter(
            store: InMemoryTrafficStore(), now: { Date(timeIntervalSince1970: 1_767_225_600) }, calendar: utcPlus8())
        meter.record(hostID: "h", direction: .sent, bytes: 1)
        #expect(meter.days().map(\.day) == ["2026-01-01"])
    }
}
