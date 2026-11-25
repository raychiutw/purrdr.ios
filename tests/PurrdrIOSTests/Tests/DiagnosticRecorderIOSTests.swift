#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PurrdrAgentFeatures
@testable import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport

/// 卡頓記錄器接在真正的聊天列表上(`ChatListViewController`):程式驅動捲動與內容更新時會產生記錄,離開聊天與進背景會停。
final class CollectingHitchSink: DiagnosticLogStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [DiagnosticEntry] = []
    var entries: [DiagnosticEntry] { lock.withLock { all } }
    func append(_ entries: [DiagnosticEntry]) { lock.withLock { all.append(contentsOf: entries) } }
    func exportFile(meta: DiagnosticEntry?) async -> URL? { nil }
    func clear() async {}
}

@Suite(.serialized)
@MainActor
struct DiagnosticRecorderIOSTests {
    static let layoutTests = ConversationLayoutTests()

    static func recorder(_ sink: CollectingHitchSink) -> DiagnosticRecorder {
        DiagnosticRecorder(
            sink: sink, defaults: UserDefaults(suiteName: "hitch-ios-\(UUID().uuidString)")!,
            system: { HitchSystemState.current() })
    }

    static func controller(of scroll: UIScrollView) -> ChatListViewController? {
        var responder: UIResponder? = scroll
        while let current = responder {
            if let found = current as? ChatListViewController { return found }
            responder = current.next
        }
        return nil
    }

    /// 卡住主執行緒(同步函式,async 環境不能直接 sleep)。
    static func blockMainThread(milliseconds: UInt32) { usleep(milliseconds * 1000) }

    static func longLines(_ count: Int) -> [String] {
        var lines = ConversationLayoutTests.lines
        for index in 0..<count {
            lines.append(ConversationLayoutTests.textLine(100 + index, "第 \(index) 則:" + ConversationLayoutTests.longText))
        }
        return lines
    }

    @Test("聊天列表可見時記錄器運作;程式驅動捲動加上內容更新時卡幀會變成事件(含同時的活動)")
    func recordsHitchesWhileVisible() async throws {
        let sink = CollectingHitchSink()
        let recorder = Self.recorder(sink)
        var mounted = try await Self.layoutTests.open(window: Self.longLines(40), hitchRecorder: recorder)
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await Self.layoutTests.waitForFollow(mounted)
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.isRunning)
        let scroll = try #require(ConversationLayoutTests.findCollectionView(mounted.window))

        // 一邊程式捲動、一邊進新內容,再卡住主執行緒 90 ms:顯示更新間隔會超過目標間隔。
        for step in 0..<6 {
            scroll.contentOffset.y = max(0, scroll.contentOffset.y - 40)
            await Self.layoutTests.push(ConversationLayoutTests.textLine(900 + step, "新訊息 \(step)"), to: &mounted)
            try await Task.sleep(for: .milliseconds(40))
            Self.blockMainThread(milliseconds: 90)
            try await Task.sleep(for: .milliseconds(40))
        }
        recorder.flush()

        let hitches = sink.entries.compactMap { if case .hitch(let event) = $0 { event } else { nil } }
        #expect(!hitches.isEmpty, "沒有記到任何卡幀事件")
        #expect(hitches.contains { $0.milliseconds >= 60 })
        #expect(hitches.contains { !$0.activity.isEmpty })
        #expect(hitches.allSatisfy { $0.system.device != "" && $0.system.os.hasPrefix("iOS") })
    }

    @Test("離開聊天(畫面移除)與進背景都會停止記錄器")
    func stopsWhenLeavingOrBackgrounded() async throws {
        let sink = CollectingHitchSink()
        let recorder = Self.recorder(sink)
        let mounted = try await Self.layoutTests.open(window: Self.longLines(10), hitchRecorder: recorder)
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let scroll = try #require(ConversationLayoutTests.findCollectionView(mounted.window))
        let controller = try #require(Self.controller(of: scroll))
        #expect(recorder.isRunning)

        controller.setSceneActive(false)
        #expect(!recorder.isRunning)
        controller.setSceneActive(true)
        #expect(recorder.isRunning)

        mounted.window.rootViewController = UIViewController()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!recorder.isRunning)
    }

    @Test("開關關閉時列表不量測:運作條件不成立、沒有任何記錄")
    func disabledRecorderNeverRuns() async throws {
        let sink = CollectingHitchSink()
        let recorder = Self.recorder(sink)
        recorder.isEnabled = false
        var mounted = try await Self.layoutTests.open(window: Self.longLines(10), hitchRecorder: recorder)
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await Self.layoutTests.waitForFollow(mounted)
        await Self.layoutTests.push(ConversationLayoutTests.textLine(950, "新訊息"), to: &mounted)
        try await Task.sleep(for: .milliseconds(100))
        Self.blockMainThread(milliseconds: 90)
        try await Task.sleep(for: .milliseconds(100))
        recorder.flush()
        #expect(!recorder.isRunning)
        #expect(sink.entries.isEmpty)
    }

    // MARK: - 開銷自檢

    /// 內容已載入的來回捲動,每一步(不含固定等待)的 layout 耗時,毫秒,由小到大。
    static func sweepStepTimes(recorder: DiagnosticRecorder?) async throws -> [Double] {
        var lines = ConversationLayoutTests.lines
        for index in 0..<120 {
            let text = index.isMultiple(of: 3)
                ? "第 \(index) 則:\n\n```swift\nlet value = \(index)\nprint(value)\n```\n\n" + ConversationLayoutTests.longText
                : "第 \(index) 則:" + ConversationLayoutTests.longText
            lines.append(ConversationLayoutTests.textLine(100 + index, text))
        }
        let mounted = try await layoutTests.open(window: lines, hitchRecorder: recorder)
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await layoutTests.waitForFollow(mounted)
        try await Task.sleep(for: .milliseconds(800))
        #expect(recorder?.isRunning ?? true, "量測時記錄器要真的在運作")
        let window = mounted.window
        let scroll = try #require(ConversationLayoutTests.findCollectionView(window))
        window.layoutIfNeeded()
        func liveBottom() -> CGFloat { scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom }
        let top = -scroll.adjustedContentInset.top
        var y = top
        while y < liveBottom() {
            _ = try await ChatScrollSweepTests.sweep(scroll, window: window, positions: [y])
            y += 60
        }
        let up = stride(from: liveBottom(), through: top, by: -60).map { $0 }
        var times: [Double] = []
        for positions in [up, up.reversed(), up] {
            times += try await ChatScrollSweepTests.sweep(scroll, window: window, positions: Array(positions)).stepMilliseconds
        }
        return times.sorted()
    }

    @Test("記錄器開著時掃描的每步 layout 耗時不明顯變差(數字印在輸出)")
    func recorderOverheadIsSmall() async throws {
        func summary(_ times: [Double]) -> (mean: Double, p50: Double, p95: Double) {
            (times.reduce(0, +) / Double(times.count), times[times.count / 2], times[times.count * 95 / 100])
        }
        let sink = CollectingHitchSink()
        let recorder = Self.recorder(sink)
        let baselineA = summary(try await Self.sweepStepTimes(recorder: nil))
        let on = summary(try await Self.sweepStepTimes(recorder: recorder))
        let baselineB = summary(try await Self.sweepStepTimes(recorder: nil))
        print("HITCHOVERHEAD off1 mean=\(baselineA.mean) p50=\(baselineA.p50) p95=\(baselineA.p95)")
        print("HITCHOVERHEAD on   mean=\(on.mean) p50=\(on.p50) p95=\(on.p95)")
        print("HITCHOVERHEAD off2 mean=\(baselineB.mean) p50=\(baselineB.p50) p95=\(baselineB.p95)")
        let baseline = max(baselineA.mean, baselineB.mean)
        #expect(on.mean <= baseline * 1.25 + 0.2, "開著 mean \(on.mean) ms 對照 \(baseline) ms")
        #expect(on.p95 <= max(baselineA.p95, baselineB.p95) * 1.25 + 0.5)
    }
}
#endif
