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

    /// Google Play 訂閱:iPhone 上有 Plus、只顯示來源,沒有購買、管理或恢復購買。
    @MainActor
    func testGooglePlaySubscriptionShowsSourceOnly() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingGooglePlayMember"])
        app.openAccountSheet()

        XCTAssertTrue(status(app).label.contains("Google Play"), status(app).label)
        XCTAssertFalse(app.buttons["account.plusCard.primary"].exists)
        XCTAssertFalse(app.buttons["account.plusCard.manage"].exists)
        XCTAssertFalse(app.buttons["account.plusCard.secondary"].exists)
        XCTAssertFalse(app.element("account.locked.hostSync").exists, "有 Plus 不該鎖定")
    }

    /// 帳單寬限:仍有 Plus,主按鈕是更新付款方式。
    @MainActor
    func testBillingGraceOffersPaymentUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingGraceMember"])
        app.openAccountSheet()

        XCTAssertTrue(status(app).label.contains("Plus still works"), status(app).label)
        XCTAssertEqual(app.buttons["account.plusCard.primary"].label, "Update Payment Method")
        XCTAssertFalse(app.element("account.locked.notifications").exists, "寬限期仍有 Plus,不該鎖定")
    }

    /// 已到期:續訂與恢復購買,通知與同步鎖定。
    @MainActor
    func testExpiredOffersRenewAndLocksFeatures() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingExpiredMember"])
        app.openAccountSheet()

        XCTAssertTrue(status(app).label.contains("Expired"), status(app).label)
        XCTAssertEqual(app.buttons["account.plusCard.primary"].label, "Renew Purrdr Plus")
        XCTAssertEqual(app.buttons["account.plusCard.secondary"].label, "Restore Purchases")
        let locked = app.element("account.locked.notifications")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: locked, search: .down, timeout: 10), "到期後通知沒有鎖定")
        XCTAssertTrue((locked.value as? String)?.contains("Subscription ended") == true, String(describing: locked.value))
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
        XCTAssertTrue(status(app).label.contains("r***@icloud.com"), status(app).label)
        let transfer = app.buttons["account.plusCard.primary"]
        XCTAssertEqual(transfer.label, "Move to This Member")
        transfer.tap()

        // 轉移完成是純告知:顯示在頁內,不彈 alert(#625)。
        XCTAssertTrue(app.element("subscription.notice").waitUntilExists(timeout: 10), "轉移完成沒有頁內提示")
        XCTAssertFalse(app.alerts.firstMatch.exists, "純告知不該彈 alert")
        XCTAssertTrue(status(app).wait(for: NSPredicate(format: "label CONTAINS 'Active'"), timeout: 10), "轉移後 Plus 沒有生效")
        XCTAssertFalse(app.buttons["account.plusCard.primary"].exists)
    }

    /// 升級合併後有另一個待處理的訂閱:帳號頁提示到商店取消。
    @MainActor
    func testPendingReviewSubscriptionShowsNotice() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPendingReviewMember"])
        app.openAccountSheet()

        let notice = app.element("account.pendingReview")
        XCTAssertTrue(notice.waitUntilExists(timeout: 10), "沒有待處理提示")
        XCTAssertTrue(notice.label.contains("avoid paying twice"), notice.label)
    }

    /// 登入中的裝置:列出裝置,撤銷另一支要先確認,撤銷後從清單消失;目前這支沒有登出鈕。
    @MainActor
    func testSignedInDevicesRevokeAnotherDevice() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        app.openAccountSheet()
        let row = app.buttons["member.signInDevices"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: row, search: .down, timeout: 10), "帳號頁沒有登入中的裝置")
        row.tap()

        let ipad = app.element("account.signInDevice.ui-session-ipad")
        XCTAssertTrue(ipad.waitUntilExists(timeout: 10), "清單沒有另一支裝置")
        XCTAssertTrue(app.element("account.signInDevice.ui-session-this").exists)
        XCTAssertFalse(app.buttons["account.signInDevice.signOut.ui-session-this"].exists, "目前這支不該有登出鈕")
        app.buttons["account.signInDevice.signOut.ui-session-ipad"].tap()
        let confirm = app.buttons["account.signInDevices.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "撤銷沒有先確認")
        confirm.tap()

        XCTAssertTrue(ipad.waitUntilGone(timeout: 10), "撤銷後裝置還在清單")
    }

    /// 登入中的裝置也能左滑登出(#626):與列上的「Sign Out」同一個動作、先確認;目前這支左滑沒有登出。
    @MainActor
    func testSignedInDevicesSwipeToSignOut() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        app.openAccountSheet()
        let row = app.buttons["member.signInDevices"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: row, search: .down, timeout: 10), "帳號頁沒有登入中的裝置")
        row.tap()

        let ipad = app.element("account.signInDevice.ui-session-ipad")
        XCTAssertTrue(ipad.waitUntilExists(timeout: 10), "清單沒有另一支裝置")
        app.element("account.signInDevice.ui-session-this").swipeLeft()
        XCTAssertFalse(app.buttons["account.signInDevice.swipeSignOut.ui-session-this"].waitUntilExists(timeout: 1), "目前這支左滑不該有登出")
        ipad.swipeLeft()
        let swipeSignOut = app.buttons["account.signInDevice.swipeSignOut.ui-session-ipad"].firstMatch
        XCTAssertTrue(swipeSignOut.waitUntilExists(timeout: 5), "左滑沒有「登出」")
        swipeSignOut.tap()
        let confirm = app.buttons["account.signInDevices.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "左滑沒有先確認")
        XCTAssertTrue(ipad.exists, "確認前列不該先被移走")
        confirm.tap()
        XCTAssertTrue(ipad.waitUntilGone(timeout: 10), "登出後裝置還在清單")
    }
}
