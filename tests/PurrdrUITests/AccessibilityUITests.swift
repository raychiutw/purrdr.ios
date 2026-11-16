import XCTest

/// 無障礙總稽核(#35)找到的問題，各自的回歸測試。
final class AccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Spaces 卡片下的 Agent 列(notes 的 Codex):預設字級時狀態與時間在右側，列的高度跟三行文字差不多，
    /// 不會在中間留一大片空白、把「Now」擠到列底(#34 截圖 01-agent-list)。
    /// 副標較長的列(weather-app 的「需要你」)也一樣：預設字級不改成上下堆疊(堆疊只在 AX 字級)。
    @MainActor
    func testAgentRowsKeepStatusBesideTextAtDefaultSize() {
        continueAfterFailure = true
        let app = XCUIApplication.launchUITesting()
        let codex = element("agent.row.demo/w3:p1", in: app)
        XCTAssertTrue(app.reveal(codex), "notes 卡片下沒有 Codex 列")
        // iPhone 17 預設字級：標題折成兩行 + 副標 + 預覽約 112pt;上下堆疊(狀態、時間各佔一行)約 132pt;
        // 狀態標題被擠成一字一行時約 188pt。
        XCTAssertLessThan(codex.frame.height, 125, "Codex 列太高:\(codex.frame)")
        let needsYou = element("agent.row.demo/w2:p1", in: app)
        XCTAssertTrue(app.reveal(needsYou))
        XCTAssertLessThan(needsYou.frame.height, 125, "「需要你」列太高(上下堆疊了):\(needsYou.frame)")
    }
}
