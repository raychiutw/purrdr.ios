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
        XCTAssertTrue(needsYou.waitUntilExists(timeout: 10))
        XCTAssertTrue(app.reveal(ledger))

        ledger.swipeRight()
        app.buttons["Pin"].firstMatch.tap()
        // 已釘選在最上方;捲回頂端。
        app.collectionViews.firstMatch.swipeDown()

        XCTAssertTrue(ledger.waitUntilExists(timeout: 5))
        XCTAssertLessThan(ledger.frame.minY, needsYou.frame.minY, "已釘選的列不在最上方")
        XCTAssertTrue(ledger.label.contains("Pinned"), "列沒有念出已釘選:\(ledger.label)")
    }

    /// 有新回覆的聊天未讀;打開讀過、回到列表後變已讀。主機與設定 sheet 的「完成」旁不放數字徽章(#322)。
    @MainActor
    func testOpeningChatMarksItRead() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))
        expectation(for: NSPredicate(format: "value == %@", "Unread"), evaluatedWith: ledger)
        waitForExpectations(timeout: 10)

        // 有需要你的 workspace 時，主機與設定 sheet 的「完成」旁也不放數字徽章(#322)。
        for (menuItem, sheet) in [("menu.hosts", "sheet.hosts"), ("menu.settings", "sheet.settings")] {
            app.buttons["toolbar.more"].tap()
            app.buttons[menuItem].tap()
            let done = app.buttons["sheet.done"]
            XCTAssertTrue(done.waitUntilExists(timeout: 5), "\(sheet) 沒有「完成」")
            XCTAssertTrue(app.descendants(matching: .any)[sheet].firstMatch.exists, "沒有開出 \(sheet)")
            XCTAssertFalse(app.descendants(matching: .any)["attention.badge"].firstMatch.exists, "\(sheet) 的「完成」旁有數字徽章")
            XCTAssertEqual(done.label, "Done", "「完成」多念了徽章")
            done.tap()
            // 等 sheet 收完再點列表，否則點擊落在收合中的 sheet 上。
            let closed = NSPredicate(format: "exists == false")
            expectation(for: closed, evaluatedWith: app.descendants(matching: .any)[sheet].firstMatch)
            waitForExpectations(timeout: 5)
        }

        ledger.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let read = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(read))
        expectation(for: NSPredicate(format: "value != %@", "Unread"), evaluatedWith: read)
        waitForExpectations(timeout: 5)
    }
}
