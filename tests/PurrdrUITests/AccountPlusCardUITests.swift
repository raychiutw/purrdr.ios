import XCTest

/// 帳號頁 Plus 卡的各狀態(#409,設計稿第 27 組)。每個情境一個假後台旗標;只驗行為與文字,不驗版面像素。
final class AccountPlusCardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func status(_ app: XCUIApplication) -> XCUIElement {
        let element = app.element("account.plusCard.status")
        XCTAssertTrue(element.waitUntilExists(timeout: 10), "沒有 Plus 卡")
        return element
    }

    /// 訂閱屬於另一個會員:恢復購買後顯示遮蔽的 email 與轉移,轉移後 Plus 生效。
    @MainActor
    func testOwnedByAnotherMemberOffersTransfer() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingOwnedByOtherMember"])
        app.openAccountSheet()
        let restore = app.buttons["account.plusCard.secondary"]
        XCTAssertTrue(restore.waitUntilExists(timeout: 10))
        restore.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 10), "沒有提示這個訂閱屬於另一個會員")
        alert.buttons["OK"].tap()

        XCTAssertTrue(status(app).label.contains("belongs to another member"), status(app).label)
        XCTAssertTrue(status(app).label.contains("r***@example.net"), status(app).label)
        let transfer = app.buttons["account.plusCard.primary"]
        XCTAssertEqual(transfer.label, "Move to This Member")
        transfer.tap()

        // 轉移完成是純告知:顯示在頁內,不彈 alert(#625)。
        XCTAssertTrue(app.element("subscription.notice").waitUntilExists(timeout: 10), "轉移完成沒有頁內提示")
        XCTAssertFalse(app.alerts.firstMatch.exists, "純告知不該彈 alert")
        XCTAssertTrue(status(app).wait(for: NSPredicate(format: "label CONTAINS 'Active'"), timeout: 10), "轉移後 Plus 沒有生效")
        XCTAssertFalse(app.buttons["account.plusCard.primary"].exists)
    }
}
