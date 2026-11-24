#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PurrdrAgentFeatures
@testable import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport

/// 聊天列表在「程式驅動的大幅跳動」下的自適應高度成本(0.51.x 實機卡頓記錄:大卡頓都在 scroll=idle、同時有大量 cell 自適應)。
/// 字級 XXXL、長 Markdown、程式碼區塊、表格:量自適應次數、位移補償次數與位移量、單步最長主執行緒阻塞。
@Suite(.serialized)
@MainActor
struct ChatSelfSizingTests {
    static let layoutTests = ConversationLayoutTests()
    static let category = UIContentSizeCategory.extraExtraExtraLarge

    static let table = """
        | 項目 | 狀態 | 說明 |
        | --- | --- | --- |
        | 匯出 | 完成 | 日期放在最前面,含逗號的備註加引號 |
        | 匯入 | 進行中 | 需要處理 BOM 與 CRLF 兩種換行 |
        | 測試 | 待辦 | 補上引號、換行與空值的案例 |
        """

    /// 長 Markdown、程式碼區塊、表格輪流出現的 Agent 回覆。
    static func heavyLines(_ count: Int, firstIndex: Int = 100) -> [String] {
        (0..<count).map { index in
            let text: String
            switch index % 4 {
            case 0: text = "第 \(index) 則:\n\n```swift\nlet value = \(index)\nfunc render() {\n    print(value)\n}\n```\n\n" + ConversationLayoutTests.longText
            case 1: text = "第 \(index) 則:\n\n" + table + "\n\n" + ConversationLayoutTests.longText
            case 2: text = "## 第 \(index) 則\n\n- 項目一\n- 項目二\n- 項目三\n\n" + ConversationLayoutTests.longText
            default: text = "第 \(index) 則:" + ConversationLayoutTests.longText
            }
            return ConversationLayoutTests.textLine(firstIndex + index, text)
        }
    }

    /// 以 `CADisplayLink` 量主執行緒更新間隔,取最長的一個(毫秒)與超過 33 ms 的次數。
    @MainActor
    final class GapMeter {
        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private(set) var longest = 0.0
        private(set) var over33 = 0

        func start() {
            longest = 0
            over33 = 0
            last = nil
            let target = Target(self)
            link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            link?.add(to: .main, forMode: .common)
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        fileprivate func tick(_ link: CADisplayLink) {
            if let last {
                let gap = (link.timestamp - last) * 1000
                longest = max(longest, gap)
                if gap > 33 { over33 += 1 }
            }
            last = link.timestamp
        }

        @MainActor
        private final class Target: NSObject {
            weak var meter: GapMeter?
            init(_ meter: GapMeter) { self.meter = meter }
            @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
        }
    }

    struct Result: CustomStringConvertible {
        var counts: ChatListSizingProbe.Counts
        var longestGap: Double
        var over33: Int
        var description: String {
            "fits=\(counts.fits) heightChanges=\(counts.heightChanges) fitMs=\(Int(counts.fitMilliseconds)) longestFitMs=\(String(format: "%.1f", counts.longestFitMilliseconds)) "
                + "layoutAdj=\(counts.layoutAdjustments) layoutAdjPts=\(Int(counts.layoutAdjustmentPoints)) "
                + "progOffsets=\(counts.programmaticOffsets) progPts=\(Int(counts.programmaticOffsetPoints)) cacheHits=\(counts.cacheHits) "
                + "longestGapMs=\(Int(longestGap)) over33=\(over33)"
        }
    }

    struct Rig {
        var mounted: ConversationLayoutTests.Mounted
        let scroll: UICollectionView
        let controller: ChatListViewController
    }

    func rig(lines: [String], paged: Bool = false) async throws -> Rig {
        let mounted = try await Self.layoutTests.open(window: lines, contentSizeCategory: Self.category, sceneActive: true, paged: paged)
        try await Self.layoutTests.waitForFollow(mounted)
        let scroll = try #require(ConversationLayoutTests.findCollectionView(mounted.window))
        let controller = try #require(HitchRecorderIOSTests.controller(of: scroll))
        return Rig(mounted: mounted, scroll: scroll, controller: controller)
    }

    /// 等排版靜下來:連續幾輪 contentSize 與 offset 都沒變。
    func settle(_ rig: Rig, maxSeconds: Double = 6) async throws {
        var stable = 0
        var last = (rig.scroll.contentSize.height, rig.scroll.contentOffset.y)
        let deadline = ContinuousClock.now + .seconds(maxSeconds)
        while stable < 8, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            rig.mounted.window.layoutIfNeeded()
            let now = (rig.scroll.contentSize.height, rig.scroll.contentOffset.y)
            stable = now == last ? stable + 1 : 0
            last = now
        }
    }

    /// 模擬讀者用手指把列表拉到某個位置:照 UIScrollView 委派的順序呼叫(開始拖曳、結束拖曳),
    /// 位移本身在沒有委派的情況下設定(測試裡 `isDragging` 不會是 true,`scrollViewDidScroll` 會被當成程式捲動)。
    func scrollAsReader(_ rig: Rig, toY y: CGFloat) async throws {
        rig.controller.scrollViewWillBeginDragging(rig.scroll)
        let delegate = rig.scroll.delegate
        rig.scroll.delegate = nil
        rig.scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        rig.mounted.window.layoutIfNeeded()
        rig.scroll.delegate = delegate
        rig.controller.scrollViewDidEndDragging(rig.scroll, willDecelerate: false)
        try await settle(rig)
    }

    func measure(_ rig: Rig, _ body: () async throws -> Void) async throws -> Result {
        let meter = GapMeter()
        rig.controller.sizingProbe.reset()
        meter.start()
        try await body()
        try await settle(rig)
        meter.stop()
        return Result(counts: rig.controller.sizingProbe.counts, longestGap: meter.longest, over33: meter.over33)
    }

    static func distanceFromBottom(_ scroll: UIScrollView) -> Int {
        Int(scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y)
    }

    // MARK: - 場景

    @Test("開啟長對話(XXXL):停在最底之前的自適應與位移補償")
    func opening() async throws {
        let mounted = try await Self.layoutTests.open(
            window: ConversationLayoutTests.lines + Self.heavyLines(100), contentSizeCategory: Self.category, sceneActive: true, paged: true)
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        let meter = GapMeter()
        meter.start()
        try await Self.layoutTests.waitForFollow(mounted)
        let scroll = try #require(ConversationLayoutTests.findCollectionView(mounted.window))
        let controller = try #require(HitchRecorderIOSTests.controller(of: scroll))
        let rig = Rig(mounted: mounted, scroll: scroll, controller: controller)
        try await settle(rig)
        meter.stop()
        let result = Result(counts: controller.sizingProbe.counts, longestGap: meter.longest, over33: meter.over33)
        print("SIZING opening \(result) distanceFromBottom=\(Self.distanceFromBottom(scroll)) following=\(controller.isFollowingLatest) contentHeight=\(Int(scroll.contentSize.height))")
        // 修前 3311pt(列高在停下之後才量準、內容變高,位移沒人補);修後停在最底。
        #expect(Self.distanceFromBottom(scroll) <= 1, "開啟後離最底還有 \(Self.distanceFromBottom(scroll))pt")
    }

    @Test("長對話(XXXL):由頂端按「跳到最新」")
    func jumpToLatestFromTop() async throws {
        let rig = try await rig(lines: ConversationLayoutTests.lines + Self.heavyLines(100), paged: true)
        defer { rig.mounted.chat.cancel(); rig.mounted.window.isHidden = true }
        try await settle(rig)
        // 先到頂端(讀者往上翻到很前面),再等排版靜下來。
        try await scrollAsReader(rig, toY: -rig.scroll.adjustedContentInset.top)
        print("SIZING readerAt offsetY=\(Int(rig.scroll.contentOffset.y)) distance=\(Self.distanceFromBottom(rig.scroll)) following=\(rig.controller.isFollowingLatest)")
        try #require(!rig.controller.isFollowingLatest, "讀者往上翻之後不該還在跟隨最新")
        let result = try await measure(rig) {
            rig.controller.jumpToLatest()
        }
        print("SIZING jumpToLatest \(result) distanceFromBottom=\(Self.distanceFromBottom(rig.scroll)) following=\(rig.controller.isFollowingLatest) contentHeight=\(Int(rig.scroll.contentSize.height))")
        // 修前:動畫跨過整段沒量過的列,停在離最底 8196pt。修後直接跳、對準最底。
        #expect(Self.distanceFromBottom(rig.scroll) <= 1, "跳到最新後離最底還有 \(Self.distanceFromBottom(rig.scroll))pt")
        #expect(result.counts.fits <= 10, "跳到最新自適應 \(result.counts.fits) 次(修前動畫途中逐列自適應)")
    }

    @Test("長對話(XXXL):跟隨最新時連續追加 Agent 回覆")
    func followingAppends() async throws {
        let rig = try await rig(lines: ConversationLayoutTests.lines + Self.heavyLines(100), paged: true)
        defer { rig.mounted.chat.cancel(); rig.mounted.window.isHidden = true }
        try await settle(rig)
        let extra = Self.heavyLines(20, firstIndex: 500)
        var mounted = rig.mounted
        let result = try await measure(rig) {
            for line in extra {
                await Self.layoutTests.push(line, to: &mounted)
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        print("SIZING followingAppends(20) \(result) distanceFromBottom=\(Self.distanceFromBottom(rig.scroll)) following=\(rig.controller.isFollowingLatest)")
        // 修前:fits 223、列高改變 161(每次追加都把已量過的列重新量一遍)、停在離最底 1264pt。
        #expect(result.counts.heightChanges <= 60, "列高改變 \(result.counts.heightChanges) 次")
        #expect(result.counts.fits <= 130, "自適應 \(result.counts.fits) 次")
        #expect(Self.distanceFromBottom(rig.scroll) <= 1, "追加後離最底還有 \(Self.distanceFromBottom(rig.scroll))pt")
    }

    @Test("長對話(XXXL):一次湊進 20 則(重連後補上、App 回前景)")
    func burstAppend() async throws {
        let rig = try await rig(lines: ConversationLayoutTests.lines + Self.heavyLines(100), paged: true)
        defer { rig.mounted.chat.cancel(); rig.mounted.window.isHidden = true }
        try await settle(rig)
        let extra = Self.heavyLines(20, firstIndex: 500)
        var mounted = rig.mounted
        let result = try await measure(rig) {
            for line in extra { await Self.layoutTests.push(line, to: &mounted) }
        }
        print("SIZING burstAppend(20) \(result) distanceFromBottom=\(Self.distanceFromBottom(rig.scroll)) following=\(rig.controller.isFollowingLatest)")
        // 修前:fits 54、列高改變 35、停在離最底 1179pt。
        #expect(result.counts.heightChanges <= 20, "列高改變 \(result.counts.heightChanges) 次")
        #expect(Self.distanceFromBottom(rig.scroll) <= 1, "一次湊進後離最底還有 \(Self.distanceFromBottom(rig.scroll))pt")
    }

    @Test("超過一個讀取視窗的長對話(XXXL):往上補讀舊頁併入")
    func loadingOlderPage() async throws {
        let rig = try await rig(lines: ConversationLayoutTests.lines + Self.heavyLines(400), paged: true)
        defer { rig.mounted.chat.cancel(); rig.mounted.window.isHidden = true }
        try await settle(rig)
        try await scrollAsReader(rig, toY: -rig.scroll.adjustedContentInset.top)
        let result = try await measure(rig) {
            await rig.mounted.model.loadOlder()
        }
        print("SIZING loadOlder \(result) contentHeight=\(Int(rig.scroll.contentSize.height)) older=\(rig.mounted.model.older)")
        // 修前:fits 96、列高改變 59。
        #expect(result.counts.heightChanges <= 35, "列高改變 \(result.counts.heightChanges) 次")
    }
}
#endif
