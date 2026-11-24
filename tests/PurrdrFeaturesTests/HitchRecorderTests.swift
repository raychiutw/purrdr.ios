import Foundation
import Testing
@testable import PurrdrAgentFeatures

/// 記下收到什麼的假儲存:`append` 就是 recorder 唯一的出口(真的實作在背景佇列寫檔)。
final class RecordingHitchSink: HitchLogStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[HitchEntry]] = []
    var appendCalls: Int { lock.withLock { batches.count } }
    var entries: [HitchEntry] { lock.withLock { batches.flatMap { $0 } } }
    func append(_ entries: [HitchEntry]) { lock.withLock { batches.append(entries) } }
    func exportFile(meta: HitchEntry?) async -> URL? { nil }
    func clear() async {}
}

extension HitchSystemState {
    static let sample = HitchSystemState(
        thermal: "nominal", lowPower: false, reduceTransparency: false, reduceMotion: false,
        device: "iPhone18,1", os: "iOS 27.0", app: "0.52.0 (1)", textSize: "L", maxFramesPerSecond: 120)
}

@MainActor
struct HitchHarness {
    let sink = RecordingHitchSink()
    let recorder: HitchRecorder
    var clock = 1000.0

    init(enabled: Bool = true, capacity: Int = 256) {
        let defaults = UserDefaults(suiteName: "hitch-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: HitchLogSettings.enabledKey)
        recorder = HitchRecorder(
            sink: sink, defaults: defaults, system: { .sample }, wallClock: { Date(timeIntervalSince1970: 1_800_000_000) },
            bufferCapacity: capacity)
        recorder.setVisible(true)
        recorder.setSceneActive(true)
    }

    /// 以 `expected` 為目標間隔、依序送出各個實際間隔的畫面。
    mutating func feed(
        _ intervals: [Double], expected: Double = 1.0 / 120, scroll: HitchScrollState = .dragging,
        offsetY: Double = 0, velocityY: Double = 0, cells: Int = 6
    ) {
        for interval in intervals {
            clock += interval
            recorder.frame(
                timestamp: clock, expectedInterval: expected, scroll: scroll, offsetY: offsetY, velocityY: velocityY,
                visibleCells: { cells })
        }
    }

    var hitches: [HitchEvent] { sink.entries.compactMap { if case .hitch(let event) = $0 { event } else { nil } } }
    var scrolls: [ScrollSummary] { sink.entries.compactMap { if case .scroll(let summary) = $0 { summary } else { nil } } }
}

@MainActor
@Suite("捲動卡頓記錄器")
struct HitchRecorderTests {
    static let frame120 = 1.0 / 120
    static let frame60 = 1.0 / 60

    // MARK: - 卡幀判定

    @Test("卡幀 = 間隔大於 1.5 倍目標間隔:ProMotion 120 Hz 與 60 Hz")
    func classifiesHitches() {
        #expect(!HitchFrameClassifier.isHitch(interval: Self.frame120, expected: Self.frame120))
        #expect(!HitchFrameClassifier.isHitch(interval: 0.0125, expected: Self.frame120))
        #expect(HitchFrameClassifier.isHitch(interval: 0.013, expected: Self.frame120))
        #expect(!HitchFrameClassifier.isHitch(interval: 0.024, expected: Self.frame60))
        #expect(HitchFrameClassifier.isHitch(interval: 0.026, expected: Self.frame60))
    }

    @Test("掉幀數 = 間隔相當於幾幀減 1,卡幀至少算 1")
    func countsDroppedFrames() {
        #expect(HitchFrameClassifier.droppedFrames(interval: 0.026, expected: Self.frame60) == 1)
        #expect(HitchFrameClassifier.droppedFrames(interval: 0.050, expected: Self.frame60) == 2)
        #expect(HitchFrameClassifier.droppedFrames(interval: 0.013, expected: Self.frame120) == 1)
        #expect(HitchFrameClassifier.droppedFrames(interval: 0.070, expected: Self.frame120) == 7)
    }

    // MARK: - 事件合併

    @Test("連續卡幀合併成一個事件:持續時間與掉幀數相加;中間有正常幀就分成兩個")
    func mergesConsecutiveHitches() {
        var harness = HitchHarness()
        harness.feed([Self.frame120, 0.050, 0.030, Self.frame120, Self.frame120, 0.040, Self.frame120])
        harness.recorder.flush()

        #expect(harness.hitches.count == 2)
        #expect(harness.hitches[0].frames == 2)
        #expect(abs(harness.hitches[0].milliseconds - 80) < 0.5)
        #expect(harness.hitches[0].droppedFrames == (6 - 1) + (4 - 1))
        #expect(harness.hitches[1].frames == 1)
        #expect(abs(harness.hitches[1].milliseconds - 40) < 0.5)
    }

    @Test("事件記下第一個卡幀當時的 scroll 狀態、位置、速度與可見 cell 數,以及系統狀態")
    func capturesContext() throws {
        var harness = HitchHarness()
        harness.feed([Self.frame120])
        harness.feed([0.060], scroll: .decelerating, offsetY: 1234.5, velocityY: -820.25, cells: 9)
        harness.feed([Self.frame120], scroll: .idle)
        harness.recorder.flush()

        let event = try #require(harness.hitches.first)
        #expect(event.scroll == .decelerating)
        #expect(event.offsetY == 1234.5)
        #expect(abs(event.velocityY - -820.25) < 0.06)
        #expect(event.visibleCells == 9)
        #expect(event.system == .sample)
    }

    @Test("同時在做的事:事件帶出卡幀前累積的內容套用、自適應、位移修正、重新配置次數,之後歸零")
    func reportsActivity() {
        var harness = HitchHarness()
        harness.feed([Self.frame120])
        harness.recorder.note(.batchApply)
        harness.recorder.note(.fit(milliseconds: 1.5))
        harness.recorder.note(.fit(milliseconds: 2.5))
        harness.recorder.note(.offsetCorrection(points: 12))
        harness.recorder.note(.offsetCorrection(points: -4))
        harness.recorder.note(.contentSizeChange(points: 30))
        harness.recorder.note(.reconfigure(count: 3))
        harness.recorder.note(.contentUpdate)
        harness.recorder.setOlderLoading(true)
        harness.feed([0.050])
        harness.feed([Self.frame120, Self.frame120])
        harness.feed([0.050, Self.frame120])
        harness.recorder.flush()

        let first = harness.hitches[0]
        #expect(first.activity.batchApplies == 1)
        #expect(first.activity.fitCount == 2)
        #expect(abs(first.activity.fitMilliseconds - 4.0) < 0.01)
        #expect(first.activity.offsetCorrections == 2)
        #expect(first.activity.offsetCorrectionPoints == 16)
        #expect(first.activity.contentSizeChanges == 1)
        #expect(first.activity.contentSizeChangePoints == 30)
        #expect(first.activity.reconfigures == 3)
        #expect(first.activity.contentUpdates == 1)
        #expect(first.olderLoading)
        // 第二個事件沒有新的活動:不沿用上一個。
        #expect(harness.hitches[1].activity.batchApplies == 0)
        #expect(harness.hitches[1].activity.fitCount == 0)
    }

    @Test("閒置時的卡幀:沒有同時的活動就不記(系統調降更新率不是卡頓),有活動才記")
    func idleHitchNeedsActivity() {
        var harness = HitchHarness()
        harness.feed([Self.frame120, 0.050, Self.frame120], scroll: .idle)
        harness.recorder.note(.batchApply)
        harness.feed([0.050, Self.frame120], scroll: .idle)
        harness.recorder.flush()

        #expect(harness.hitches.count == 1)
        #expect(harness.hitches[0].activity.batchApplies == 1)
    }

    // MARK: - 捲動手勢摘要

    @Test("一次捲動(拖曳到減速結束)結束時記一筆摘要:秒數、平均與最大幀間隔、卡幀事件數、卡幀時間占比")
    func summarizesScrollGesture() throws {
        var harness = HitchHarness()
        harness.feed([Self.frame120, Self.frame120], scroll: .idle)
        harness.feed([Self.frame120, Self.frame120, 0.058], scroll: .dragging)
        harness.feed([Self.frame120, Self.frame120, Self.frame120], scroll: .decelerating)
        harness.feed([Self.frame120], scroll: .idle)
        harness.recorder.flush()

        #expect(harness.scrolls.count == 1)
        let summary = try #require(harness.scrolls.first)
        #expect(summary.frames == 6)
        #expect(summary.hitchEvents == 1)
        #expect(abs(summary.maxIntervalMilliseconds - 58) < 0.5)
        // 卡幀時間 = 超出目標間隔的部分(58 - 8.33 ms)。
        #expect(abs(summary.hitchMilliseconds - 49.7) < 0.5)
        let seconds = 5 * Self.frame120 + 0.058
        #expect(abs(summary.seconds - seconds) < 0.01)
        #expect(abs(summary.hitchTimeRatio - 0.0497 / seconds) < 0.01)
        #expect(abs(summary.averageIntervalMilliseconds - seconds / 6 * 1000) < 0.5)
    }

    @Test("離開(停止記錄)時,進行中的卡幀事件與捲動摘要都收尾並交出")
    func stopFinishesOpenRecords() {
        var harness = HitchHarness()
        harness.feed([Self.frame120, 0.050], scroll: .dragging)
        harness.recorder.setVisible(false)

        #expect(harness.hitches.count == 1)
        #expect(harness.scrolls.count == 1)
    }

    // MARK: - 開關與執行條件

    @Test("開關關閉時零記錄:畫面、活動、flush 都不產生任何東西,也不寫儲存")
    func disabledRecordsNothing() {
        var harness = HitchHarness(enabled: false)
        #expect(!harness.recorder.isRunning)
        harness.feed([Self.frame120, 0.080, Self.frame120], scroll: .dragging)
        harness.recorder.note(.batchApply)
        harness.recorder.setVisible(false)
        harness.recorder.flush()

        #expect(harness.sink.appendCalls == 0)
    }

    @Test("只在可見且 scenePhase 為 active 時運作;開關即時生效,存進 UserDefaults,預設開啟")
    func runningConditions() {
        let defaults = UserDefaults(suiteName: "hitch-\(UUID().uuidString)")!
        #expect(HitchLogSettings.isEnabled(defaults))
        let recorder = HitchRecorder(sink: RecordingHitchSink(), defaults: defaults, system: { .sample })
        var changes: [Bool] = []
        recorder.onRunningChanged = { changes.append($0) }

        recorder.setVisible(true)
        #expect(!recorder.isRunning)
        recorder.setSceneActive(true)
        #expect(recorder.isRunning)
        recorder.setSceneActive(false)
        #expect(!recorder.isRunning)
        recorder.setSceneActive(true)
        recorder.isEnabled = false
        #expect(!recorder.isRunning)
        #expect(!HitchLogSettings.isEnabled(defaults))
        recorder.isEnabled = true
        recorder.setVisible(false)
        #expect(!recorder.isRunning)
        #expect(changes == [true, false, true, false, true, false])
    }

    // MARK: - 儲存

    @Test("畫面回呼只累加到記憶體:flush 才交給儲存,而且一次交出")
    func frameDoesNotTouchStorage() {
        var harness = HitchHarness()
        harness.feed([Self.frame120, 0.050, Self.frame120, 0.050, Self.frame120])
        #expect(harness.sink.appendCalls == 0)
        harness.recorder.flush()
        #expect(harness.sink.appendCalls == 1)
        harness.recorder.flush()
        #expect(harness.sink.appendCalls == 1)
    }

    @Test("環形緩衝滿了丟最舊的,留最新的")
    func ringBufferDropsOldest() {
        var buffer = HitchRingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.drain() == [3, 4, 5])
        #expect(buffer.drain().isEmpty)
        var harness = HitchHarness(capacity: 2)
        harness.feed([0.050, Self.frame120, 0.050, Self.frame120, 0.050, Self.frame120])
        harness.recorder.flush()
        #expect(harness.sink.entries.count == 2)
    }

    @Test("大小上限:丟最舊的整行,留最新的;降到上限的八成以下避免每次都重寫")
    func trimsOldestLines() {
        let lines = (0..<10).map { "\($0)" + String(repeating: "x", count: 99) }
        let total = lines.map { $0.utf8.count + 1 }.reduce(0, +)
        #expect(HitchLogTrimmer.trim(lines, maxBytes: 10_000) == lines)
        let trimmed = HitchLogTrimmer.trim(lines, maxBytes: total - 1)
        #expect(trimmed.last == lines.last)
        #expect(trimmed.count < lines.count)
        #expect(trimmed.map { $0.utf8.count + 1 }.reduce(0, +) <= Int(Double(total - 1) * 0.8))
        #expect(trimmed == Array(lines.suffix(trimmed.count)))
        #expect(HitchLogTrimmer.trim(lines, maxBytes: 10).isEmpty)
    }

    // MARK: - JSON Lines

    @Test("每筆是單行 JSON,帶 schema 版本與種類;只有白名單欄位,沒有任何內容或主機資料")
    func encodesWhitelistedFieldsOnly() throws {
        var harness = HitchHarness()
        harness.feed([Self.frame120, 0.050, Self.frame120], scroll: .dragging, offsetY: 10, velocityY: 2, cells: 4)
        harness.recorder.setVisible(false)
        let metrics = HitchEntry.metrics(HitchMetricsDigest(
            periodStart: Date(timeIntervalSince1970: 1_800_000_000), periodEnd: Date(timeIntervalSince1970: 1_800_086_400),
            scrollHitchTimeRatio: 3.2, hangCount: 2, longestHangSeconds: 4.5, app: "0.52.0 (1)", os: "iOS 27.0"))

        let base: Set<String> = ["v", "kind", "t"]
        let allowed: [String: Set<String>] = [
            "hitch": base.union([
                "ms", "frames", "dropped", "scroll", "offsetY", "velocityY", "cells", "applies", "fits", "fitMs", "offsetFixes",
                "offsetFixPts", "sizeChanges", "sizePts", "reconfigures", "contentUpdates", "olderLoading", "working",
                "thermal", "lowPower", "reduceTransparency", "reduceMotion", "device", "os", "app", "textSize", "maxFps",
            ]),
            "scroll": base.union([
                "seconds", "frames", "avgMs", "maxMs", "hitches", "hitchMs", "hitchRatio", "working",
                "thermal", "lowPower", "device", "os", "app",
            ]),
            "metrics": base.union(["periodStart", "periodEnd", "scrollHitchTimeRatio", "hangs", "longestHangSeconds", "app", "os"]),
        ]

        let entries = harness.sink.entries + [metrics]
        #expect(entries.count == 3)
        for entry in entries {
            let line = HitchLogEncoder.line(entry)
            #expect(!line.contains("\n"))
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["v"] as? Int == HitchLogEncoder.schemaVersion)
            let kind = try #require(object["kind"] as? String)
            let keys = Set(object.keys)
            let permitted = try #require(allowed[kind])
            #expect(keys.isSubset(of: permitted), "多出欄位:\(keys.subtracting(permitted))")
        }
        let hitchEntry = try #require(harness.sink.entries.first { if case .hitch = $0 { true } else { false } })
        let object = try #require(JSONSerialization.jsonObject(with: Data(HitchLogEncoder.line(hitchEntry).utf8)) as? [String: Any])
        #expect(object["scroll"] as? String == "dragging")
        #expect(object["cells"] as? Int == 4)
        #expect(object["device"] as? String == "iPhone18,1")
        #expect(object["t"] as? String == "2027-01-15T08:00:00Z")
    }
}
