#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PurrdrAgentFeatures
@testable import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport

/// #508:內容已載入、沒有串流時的純捲動。把長對話放進真正的聊天列表,程式驅動 `contentOffset` 由底掃到頂再掃回來,
/// 量每一步的位移是否被 layout 補償(反向位移)與 `contentSize` 變動;第二輪(列高都量過)應該完全平穩。
@Suite(.serialized)
@MainActor
struct ChatScrollSweepTests {
    struct Sweep {
        var steps = 0
        var offsetCorrections = 0
        var contentSizeChanges = 0
        var largestCorrection: CGFloat = 0
        var milliseconds = 0.0
        /// 每一步(不含固定等待)的 layout 耗時,毫秒。
        var stepMilliseconds: [Double] = []
    }

    static let layoutTests = ConversationLayoutTests()

    static func sweep(_ scroll: UIScrollView, window: UIWindow, positions: [CGFloat]) async throws -> Sweep {
        var result = Sweep()
        var lastSize = scroll.contentSize.height
        let start = ContinuousClock.now
        for y in positions {
            let before = ContinuousClock.now
            scroll.contentOffset.y = y
            window.layoutIfNeeded()
            let mid = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(4))
            let resume = ContinuousClock.now
            window.layoutIfNeeded()
            let after = ContinuousClock.now
            func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
            result.stepMilliseconds.append(ms(mid - before) + ms(after - resume))
            result.steps += 1
            let correction = scroll.contentOffset.y - y
            if abs(correction) > 0.5 {
                result.offsetCorrections += 1
                result.largestCorrection = max(result.largestCorrection, abs(correction))
            }
            if abs(scroll.contentSize.height - lastSize) > 0.5 { result.contentSizeChanges += 1 }
            lastSize = scroll.contentSize.height
        }
        let elapsed = ContinuousClock.now - start
        result.milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return result
    }

    @Test("內容已載入:來回捲動第二輪不再有位移補償或內容高度變動")
    func secondSweepIsSmooth() async throws {
        var lines = ConversationLayoutTests.lines
        for index in 0..<120 {
            let text = index.isMultiple(of: 3)
                ? "第 \(index) 則:\n\n```swift\nlet value = \(index)\nprint(value)\n```\n\n" + ConversationLayoutTests.longText
                : "第 \(index) 則:" + ConversationLayoutTests.longText
            lines.append(ConversationLayoutTests.textLine(100 + index, text))
        }
        let mounted = try await Self.layoutTests.open(window: lines)
        defer { mounted.chat.cancel() }
        try await Self.layoutTests.waitForFollow(mounted)
        try await Task.sleep(for: .milliseconds(800))
        let window = mounted.window
        let scroll = try #require(ConversationLayoutTests.findCollectionView(window))
        window.layoutIfNeeded()

        func liveBottom() -> CGFloat { scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom }
        let top = -scroll.adjustedContentInset.top
        // 暖身:由頂掃到(會隨量測變長的)底,讓每一列都量過一次。
        var warmup = Sweep()
        var y = top
        while y < liveBottom() {
            warmup = try await Self.sweep(scroll, window: window, positions: [y])
            y += 60
        }
        let bottom = liveBottom()
        let up = stride(from: bottom, through: top, by: -60).map { $0 }
        let down = Array(up.reversed())
        let second = try await Self.sweep(scroll, window: window, positions: up)
        let third = try await Self.sweep(scroll, window: window, positions: down)
        let fourth = try await Self.sweep(scroll, window: window, positions: up)
        let sorted = second.stepMilliseconds.sorted()
        print("SWEEPSTEP p50=\(sorted[sorted.count / 2]) p95=\(sorted[sorted.count * 95 / 100]) max=\(sorted.last!) over16=\(sorted.filter { $0 > 16 }.count) sum=\(sorted.reduce(0, +))")
        print("SWEEP second=\(second) third=\(third) fourth=\(fourth) contentHeight=\(scroll.contentSize.height) lastWarm=\(warmup)")
        #expect(second.offsetCorrections == 0, "掃描位移補償 \(second.offsetCorrections) 次,最大 \(second.largestCorrection)pt")
        #expect(second.contentSizeChanges == 0, "第二輪內容高度變動 \(second.contentSizeChanges) 次")
        #expect(third.offsetCorrections == 0 && third.contentSizeChanges == 0 && fourth.offsetCorrections == 0, "後續 \(third) \(fourth)")
    }
}
#endif
