import Foundation
import Testing

@testable import PurrdrCore

/// 畫面解析熱路徑(#585):即時預覽每行都會去 ANSI;正規式要是常數、沒有 ESC 就略過。
@Suite("畫面解析熱路徑")
struct ScreenParsingHotPathTests {
    private static var recordedScreen: String { PromptSuggestionTests.screen("typed") }

    @Test("沒有 ESC 的文字原樣回傳")
    func plainTextUnchanged() {
        let plain = "line one\r\n  ❯ 1. Yes\r\n[Image #3] done"
        #expect(ANSIText.strip(plain) == plain)
    }

    @Test("上傳圖片標記:有標記的行去掉標記、整行只剩標記時略過")
    func imageMarkerStillStripped() {
        let result = UploadedImages.extract(from: "看 [Image #2] 這個\n[Image #3]\n結尾")
        #expect(result.text == "看  這個\n結尾")
    }

    @Test("基準:錄製畫面去 ANSI 與解析 2000 次(只印出耗時,不斷言)")
    func benchmark() {
        let screen = Self.recordedScreen
        let start = ContinuousClock.now
        var sink = 0
        for _ in 0..<2000 {
            sink &+= ANSIText.strip(screen).count
            sink &+= BlockedPromptParser.parse(screen: screen, agentKind: "claude") == nil ? 0 : 1
            sink &+= SlashPanelParser.parse(screen: screen, agentKind: "claude") == nil ? 0 : 1
            sink &+= UploadedImages.extract(from: "hello world\nsecond line").text.count
        }
        let elapsed = ContinuousClock.now - start
        func time(_ label: String, _ body: () -> Int) {
            let t = ContinuousClock.now
            var n = 0
            for _ in 0..<2000 { n &+= body() }
            let d = ContinuousClock.now - t
            print("BENCH-585 \(label) ms=\(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) n=\(n)")
        }
        time("strip") { ANSIText.strip(screen).count }
        time("blocked") { BlockedPromptParser.parse(screen: screen, agentKind: "claude") == nil ? 0 : 1 }
        time("slash") { SlashPanelParser.parse(screen: screen, agentKind: "claude") == nil ? 0 : 1 }
        time("upload") { UploadedImages.extract(from: "hello world\nsecond line").text.count }
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("BENCH-585 ms=\(ms) sink=\(sink)")
        #expect(sink >= 0)
    }
}
