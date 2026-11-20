import XCTest

/// 未讀標示、「已釘選」群組、各組數量、需處理數量與滑動提示(#41;行為規格 F2.2、F2.5–F2.8),走 Demo 主機。
final class UnreadPinnedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
    }

    /// 釘選後列移到 Agents 檢視最上方(在「需要你」之前),列念出「已釘選」(#244 單一清單)。
    @MainActor
    func testPinnedRowMovesToTop() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        let needsYou = row("w2:p1", in: app)
        XCTAssertTrue(needsYou.waitForExistence(timeout: 10))
        XCTAssertTrue(app.reveal(ledger))

        ledger.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        // 已釘選在最上方;捲回頂端。
        app.collectionViews.firstMatch.swipeDown()

        XCTAssertTrue(ledger.waitForExistence(timeout: 5))
        XCTAssertLessThan(ledger.frame.minY, needsYou.frame.minY, "已釘選的列不在最上方")
        XCTAssertTrue(ledger.label.contains("Pinned"), "列沒有念出已釘選:\(ledger.label)")
    }

    /// 有新回覆的聊天未讀;打開讀過、回到列表後變已讀。主機 sheet 的「完成」旁顯示需處理的 workspace 數。
    @MainActor
    func testOpeningChatMarksItRead() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))
        expectation(for: NSPredicate(format: "value == %@", "Unread"), evaluatedWith: ledger)
        waitForExpectations(timeout: 10)

        app.buttons["toolbar.more"].tap()
        app.buttons["menu.hosts"].tap()
        let badge = app.descendants(matching: .any)["attention.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "主機 sheet 的「完成」旁沒有數字")
        XCTAssertTrue(badge.label.contains("2 workspaces need you"), "數字:\(badge.label)")
        app.buttons["sheet.done"].tap()

        ledger.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let read = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(read))
        expectation(for: NSPredicate(format: "value != %@", "Unread"), evaluatedWith: read)
        waitForExpectations(timeout: 5)
    }
}
