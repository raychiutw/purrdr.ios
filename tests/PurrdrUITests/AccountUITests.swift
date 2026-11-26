import XCTest

/// 帳號頁(#246、#409):右上角帳號鈕、Purrdr Plus 卡、未開通時通知與同步鎖住。
/// 預設未加入會員;`-uiTestingMember`／`-uiTestingPlusMember` 以假後台的會員啟動。
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 已加入會員、未開通(`-uiTestingMember`,同一次啟動由上而下,原本 4 個測試合併):
    /// 顯示會員 email 與登入方式;刪除會員(#322)按鈕寫「Delete Member」不帶刪節號、按下仍先跳確認(取消);
    /// 登出(#412)先說明會停止這支裝置的通知、確認後才登出(取消);已登入、未開通時通知與同步鎖定:列仍可點,
    /// 說明原因與下一步,沒有開關(#409),說明裡的連結開付費牆;返回後 Plus 卡主按鈕開通,點了推入付費牆。
    @MainActor
    func testMemberDeleteSignOutLockedFeaturesAndActivationFromPaywall() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        app.openAccountSheet()

        XCTAssertTrue(app.staticTexts["ray@example.com"].firstMatch.waitUntilExists(timeout: 10), "沒有顯示會員")
        XCTAssertTrue(app.staticTexts["Apple"].exists, "沒有顯示登入方式")
        let action = app.buttons["account.plusCard.primary"]
        XCTAssertTrue(action.waitUntilExists(timeout: 10), "沒有開通按鈕")
        XCTAssertEqual(action.label, "Activate Purrdr Plus")
        XCTAssertTrue(app.buttons["account.plusCard.secondary"].exists, "沒有恢復購買")

        // 刪除會員:沒有訂閱的會員按刪除直接跳確認,先取消。
        let delete = app.buttons["member.delete"]
        app.scrollIntoView(delete, search: .down)
        XCTAssertTrue(delete.waitUntilExists(timeout: 10), "帳號頁沒有刪除會員")
        XCTAssertEqual(delete.label, "Delete Member")
        delete.tap()
        let deleteAlert = app.alerts["Delete Member?"]
        XCTAssertTrue(deleteAlert.waitUntilExists(timeout: 5), "沒有訂閱的會員按刪除要直接跳確認")
        XCTAssertFalse(app.otherElements["member.deleteSubscription"].exists, "沒有訂閱不該先出現訂閱說明頁")
        deleteAlert.buttons["Cancel"].tap()
        XCTAssertTrue(deleteAlert.waitUntilGone(timeout: 5), "取消後刪除確認沒有收起")

        // 登出:先說明,取消後仍在帳號頁。
        let signOut = app.buttons["member.signOut"]
        app.scrollIntoView(signOut, search: .down)
        XCTAssertTrue(signOut.waitUntilExists(timeout: 10))
        signOut.tap()
        let signOutSheet = app.sheets["Sign Out?"]
        XCTAssertTrue(signOutSheet.waitUntilExists(timeout: 5), "登出前沒有說明")
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(signOutSheet.waitUntilGone(timeout: 5), "取消後登出說明沒有收起")
        XCTAssertTrue(signOut.exists, "取消後仍在帳號頁")

        let locked = app.element("account.locked.hostSync")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: locked, search: .both, timeout: 10), "沒有鎖定的主機同步列")
        XCTAssertTrue((locked.value as? String)?.contains("Needs Purrdr Plus") == true, "鎖定列沒有寫需要 Purrdr Plus:\(String(describing: locked.value))")
        XCTAssertTrue(app.element("account.locked.notifications").exists, "沒有鎖定的通知列")
        XCTAssertFalse(app.switches["account.push.demo"].exists, "未開通不該有通知開關")
        XCTAssertFalse(app.switches["settings.hostSync"].exists, "未開通不該有主機同步開關")

        locked.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitUntilExists(timeout: 5), "點鎖定列沒有說明")
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Activate it from'")).firstMatch.exists)
        app.buttons["account.locked.openPlus"].firstMatch.tap()
        XCTAssertTrue(app.element("plus.benefits").waitUntilExists(timeout: 10), "說明裡的「Purrdr Plus」沒有開付費牆")

        // 返回帳號頁,Plus 卡主按鈕開通,點了推入付費牆(#409)。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.scrollSheet("sheet.account", to: action, search: .both, timeout: 10), "返回後沒有回到帳號頁的開通按鈕")
        action.tap()
        XCTAssertTrue(app.element("plus.benefits").waitUntilExists(timeout: 10), "沒有推入付費牆")
    }

    // MARK: - 輔助

}
