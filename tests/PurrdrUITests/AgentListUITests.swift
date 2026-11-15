import XCTest

final class AgentListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// tracer bullet:app → 畫面 model → herdr client → 主機通道(Demo 主機)整條路徑都走正式程式。
    @MainActor
    func testLaunchShowsDemoHostAgent() {
        let app = XCUIApplication.launchUITesting()

        let row = app.descendants(matching: .any)["agent.row.w1:p1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
        XCTAssertTrue(row.label.contains("Tidy up the CSV export"), "列標題不對:\(row.label)")
        XCTAssertTrue(row.label.contains("Claude Code · ledger"), "列副標不對:\(row.label)")
        XCTAssertTrue(row.label.contains("Done"), "列沒有狀態文字:\(row.label)")
    }
}
