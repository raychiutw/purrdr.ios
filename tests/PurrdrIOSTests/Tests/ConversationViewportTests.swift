#if os(iOS)
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import SwiftUI
import Testing
import UIKit
@testable import PurrdrFeatures

/// 可見範圍小(上方卡片、軟體鍵盤擠掉空間)時打開長對話，畫面不可整片空白(#191)。以真正的 `ConversationView` 與 Demo 主機驗證。
@Suite(.serialized)
@MainActor
struct ConversationViewportTests {
    /// 視窗高度:874 是 iPhone 17 全螢幕，越矮可見範圍越小;You should know 卡片(約 285pt)在輸入列上方，再擠掉一截。
    /// 874＋卡片就是 #191 回報的 ledger Demo 狀態(可見範圍約 254pt)。
    @Test("打開長對話：可見範圍小也顯示訊息", arguments: zip([874.0, 700.0, 580.0, 874.0, 760.0, 700.0], [false, false, false, true, true, true]))
    func longConversationShowsMessages(windowHeight: Double, showsNote: Bool) async throws {
        let demo = DemoHost(scenario: .largeOutputOnPrompt)
        let model = ConversationModel(
            client: HerdrClient(channel: demo), transcripts: TranscriptReader(channel: demo),
            paneID: "w1:p1", knownSessionID: nil, cache: InMemoryConversationCache()
        )
        if showsNote {
            let notes = YouShouldKnowModel(host: YouShouldKnowHost(channel: demo), hostID: "demo", consent: InMemoryHostWriteConsentStore())
            await notes.refresh()
            try #require(!notes.notes.isEmpty, "Demo 主機沒有註記")
            model.youShouldKnow = notes
        }
        let window = try mount(NavigationStack { ConversationView(model: model) }, height: windowHeight)
        // 測試視窗沒有 scene,`scenePhase` 不是 active,畫面自己的 `.task` 不讀對話：由測試讀。
        let reading = Task { await model.run() }
        defer {
            reading.cancel()
            window.isHidden = true
        }
        try await waitUntil { !model.entries.isEmpty }
        await settle(seconds: 2)

        let scrollView = try #require(Self.first(UIScrollView.self, in: window), "沒有捲動視圖")
        let visibleRange = Self.visibleRange(of: scrollView, in: window)
        #expect(visibleRange.height >= 44, "可見範圍只有 \(visibleRange.height)pt")
        #expect(Self.drawnLayers(in: scrollView, within: visibleRange, of: window) > 0,
                "視窗高 \(windowHeight)、卡片 \(showsNote):可見範圍 \(visibleRange) 整片空白(位置 \(scrollView.contentOffset.y)、內容高 \(scrollView.contentSize.height))")
    }

    // MARK: - 輔助

    private func mount(_ view: some View, height: Double) throws -> UIWindow {
        // package 測試沒有 app 宿主、也沒有 window scene;`UIWindow(frame:)` 已 deprecated,經 UIView 的 metatype 建立。
        let windowType: UIView.Type = UIWindow.self
        let window = try #require(windowType.init(frame: CGRect(x: 0, y: 0, width: 402, height: height)) as? UIWindow)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// 捲動視圖扣掉上下 inset(導覽列、輸入列)後的範圍，視窗座標。
    private static func visibleRange(of scrollView: UIScrollView, in window: UIWindow) -> CGRect {
        let frame = scrollView.convert(scrollView.bounds, to: window)
        let insets = scrollView.adjustedContentInset
        return CGRect(x: frame.minX, y: frame.minY + insets.top, width: frame.width,
                      height: max(0, frame.height - insets.top - insets.bottom))
    }

    /// 可見範圍內畫出來的圖層(文字等);整片空白是 0。測試視窗不經 render server,截圖與 VoiceOver 樹都拿不到，所以直接看圖層。
    private static func drawnLayers(in scrollView: UIScrollView, within range: CGRect, of window: UIWindow) -> Int {
        var drawn = 0
        func visit(_ layer: CALayer) {
            if layer.contents != nil, layer.convert(layer.bounds, to: window.layer).intersects(range) { drawn += 1 }
            layer.sublayers?.forEach(visit)
        }
        visit(scrollView.layer)
        return drawn
    }

    private static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = first(type, in: child) { return match }
        }
        return nil
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            try #require(clock.now < deadline, "等待逾時")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 讓出主執行緒，讓 SwiftUI 排版與捲動定下來(`RunLoop.run` 等不到排到主執行緒的工作)。
    private func settle(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
