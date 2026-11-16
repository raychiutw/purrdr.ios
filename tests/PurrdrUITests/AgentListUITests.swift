import XCTest

final class AgentListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agent.row.\(paneID)"].firstMatch
    }

    /// tracer bullet:app → 畫面 model → herdr client → 主機通道(Demo 主機)整條路徑都走正式程式。
    @MainActor
    func testLaunchShowsDemoHostAgent() {
        let app = XCUIApplication.launchUITesting()

        let row = row("w1:p1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
        XCTAssertTrue(row.label.contains("Tidy up the CSV export"), "列標題不對:\(row.label)")
        XCTAssertTrue(row.label.contains("Claude Code · demo/ledger"), "列副標不對:\(row.label)")
        XCTAssertTrue(row.label.contains("Done"), "列沒有狀態文字:\(row.label)")
    }

    /// 「需要你」在最上面，並以文字(不只顏色)說明在等輸入;工作中的列右欄是「Now」。
    @MainActor
    func testNeedsYouComesFirstWithTextualStatus() {
        let app = XCUIApplication.launchUITesting()

        let needsYou = row("w2:p1", in: app)
        let working = row("w3:p1", in: app)
        let done = row("w1:p1", in: app)
        XCTAssertTrue(needsYou.waitForExistence(timeout: 10))
        XCTAssertTrue(needsYou.label.contains("Needs You"), "沒有「需要你」文字:\(needsYou.label)")
        XCTAssertTrue(needsYou.label.contains("Waiting for your input"), "沒有等待輸入的預覽:\(needsYou.label)")
        XCTAssertTrue(working.label.contains("Sync notes to Markdown"), "Codex 標題沒去掉資料夾:\(working.label)")
        XCTAssertTrue(working.label.contains("Now"), "工作中的列沒有「Now」:\(working.label)")
        XCTAssertLessThan(needsYou.frame.minY, working.frame.minY)
        XCTAssertLessThan(working.frame.minY, done.frame.minY)
    }

    @MainActor
    func testSearchFiltersAgents() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(row("w1:p1", in: app).waitForExistence(timeout: 10))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "沒有搜尋欄")
        search.tap()
        search.typeText("weather")

        XCTAssertTrue(row("w2:p1", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row("w1:p1", in: app).exists, "不符合的列仍在")
        XCTAssertFalse(row("w3:p1", in: app).exists, "不符合的列仍在")

        search.typeText("zzz")
        XCTAssertTrue(app.staticTexts["No Matching Agents"].waitForExistence(timeout: 5), "沒有「無符合結果」的說明")
    }
}
