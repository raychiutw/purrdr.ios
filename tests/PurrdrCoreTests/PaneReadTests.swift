import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 讀 pane 畫面(`pane.read`,行為規格 §3.4、§5.1、R-Q01)。
@Suite("讀 pane 畫面")
struct PaneReadTests {
    @Test("pane.read 讀 visible 40 行(alternate screen 的 recent 是空的),bridge 不送 EOF,回傳畫面文字")
    func readsVisibleScreen() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.bridge(), reply: .recorded("pane.read.visible.ndjson"))

        let text = try await HerdrClient(channel: host).readPane(paneID: "w1:pA")

        #expect(text == PaneScreens.text("claude-idle").replacingOccurrences(of: "❯ \n", with: "❯\n"))
        let execution = try #require(await host.executions.first)
        #expect(execution.stdinText == #"{"id":"purrdr:pane.read","method":"pane.read","params":{"lines":40,"pane_id":"w1:pA","source":"visible"}}"# + "\n")
        #expect(execution.closedStdin == false)
    }
}
