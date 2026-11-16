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

    /// 滑動提示在列表底部，第一次用了滑動面板的動作後消失(列出現在畫面上不算)。
    @MainActor
    func testSwipeHintDisappearsAfterFirstSwipe() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        // 提示在列表最底下(Claude 用量之後);列表是 lazy,捲到底才在 accessibility tree 裡。
        let hint = app.descendants(matching: .any)["agentList.swipeHint"].firstMatch
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "列表底部沒有滑動提示")
        app.collectionViews.firstMatch.swipeDown()

        ledger.swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        app.collectionViews.firstMatch.swipeUp()

        XCTAssertTrue(hint.waitForNonExistence(timeout: 5), "用過滑動動作後提示仍在")
    }

    /// 釘選後列移到最上方的「已釘選」組，組標題帶數量，列念出「已釘選」。
    @MainActor
    func testPinnedRowMovesToPinnedSection() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        let needsYou = app.descendants(matching: .any)["agentList.section.needsYou"].firstMatch
        XCTAssertTrue(needsYou.waitForExistence(timeout: 5))
        XCTAssertTrue(needsYou.label.contains("1"), "組標題沒有數量:\(needsYou.label)")

        ledger.swipeRight()
        app.buttons["Pin"].firstMatch.tap()

        let pinned = app.descendants(matching: .any)["agentList.section.pinned"].firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "沒有「已釘選」組")
        XCTAssertTrue(pinned.label.contains("Pinned") && pinned.label.contains("1"), "組標題:\(pinned.label)")
        XCTAssertLessThan(pinned.frame.minY, needsYou.frame.minY, "「已釘選」不在最上方")
        XCTAssertTrue(row("w1:p1", in: app).label.contains("Pinned"), "列沒有念出已釘選:\(row("w1:p1", in: app).label)")
    }

    /// 有新回覆的聊天未讀;打開讀過、回到列表後變已讀。主機 sheet 的「完成」旁顯示需處理的 workspace 數。
    @MainActor
    func testOpeningChatMarksItRead() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
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
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value != %@", "Unread"), evaluatedWith: read)
        waitForExpectations(timeout: 5)
    }
}
