import XCTest

/// 帳號頁(#246、#409):右上角帳號鈕、Purrdr Plus 卡、未開通時通知與同步鎖住。
/// 預設未加入會員;`-uiTestingMember`／`-uiTestingPlusMember`／`-uiTestingLinkMerge` 以假後台的會員啟動。
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 已加入會員、未開通(`-uiTestingLinkMerge`:假後台的會員與 `-uiTestingMember` 相同,只多了連結 Google 時發現已屬另一個會員;
    /// 同一次啟動由上而下,原本 5 個測試合併):
    /// 顯示會員 email 與登入方式;刪除會員(#322)按鈕寫「Delete Member」不帶刪節號、按下仍先跳確認(取消);
    /// 登出(#412)先說明會停止這支裝置的通知、確認後才登出(取消);已登入、未開通時通知與同步鎖定:列仍可點,
    /// 說明原因與下一步,沒有開關(#409),說明裡的連結開付費牆;返回後 Plus 卡主按鈕開通,點了推入付費牆;
    /// 最後(合併後登入方式多了 Google,所以放最後)返回帳號頁、推入「登入方式」(#410),新增 Google 發現已屬另一個會員:
    /// 出合併確認頁、兩邊摘要都在,確認後合併、回到登入方式有兩種。
    @MainActor
    func testMemberDeleteSignOutLockedFeaturesActivationFromPaywallAndLinkMerge() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingLinkMerge"])
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
        XCTAssertFalse(app.element("account.locked.notifications").exists, "通知不再需要 Plus(#675),不該鎖定")
        XCTAssertTrue(app.element("account.notifications").exists, "沒有可進入的通知列")
        XCTAssertFalse(app.switches["account.push.demo"].exists, "未開通不該有通知開關")
        XCTAssertFalse(app.switches["settings.hostSync"].exists, "未開通不該有主機同步開關")

        locked.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitUntilExists(timeout: 5), "點鎖定列沒有說明")
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Activate it from'")).firstMatch.exists)
        app.buttons["account.locked.openPlus"].firstMatch.tap()
        XCTAssertTrue(app.element("plus.benefits").waitUntilExists(timeout: 10), "說明裡的「Purrdr Plus」沒有開付費牆")

        // 返回帳號頁,Plus 卡主按鈕開通,點了推入付費牆(#409)。
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.scrollSheet("sheet.account", to: action, search: .both, timeout: 10), "返回後沒有回到帳號頁的開通按鈕")
        action.tap()
        XCTAssertTrue(app.element("plus.benefits").waitUntilExists(timeout: 10), "沒有推入付費牆")

        // 登入方式與合併(#410):從付費牆返回帳號頁,推入「登入方式」。
        app.buttons["BackButton"].firstMatch.tap()
        let methods = app.element("member.signInMethods")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: methods, search: .down, timeout: 10), "帳號頁沒有登入方式")
        methods.tap()
        XCTAssertTrue(app.element("member.identity.apple").waitUntilExists(timeout: 10), "沒有開出登入方式")

        app.buttons["member.signIn.google"].tap()

        XCTAssertTrue(app.element("sheet.merge").waitUntilExists(timeout: 10), "沒有開出合併確認")
        XCTAssertTrue(app.element("member.merge.current").exists)
        XCTAssertTrue(app.element("member.merge.other").exists)
        app.assertModalToolbar(close: "member.merge.cancel", confirm: "member.merge.confirm")
        let confirm = app.buttons["member.merge.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.element("member.identity.google").waitUntilExists(timeout: 10), "合併後應該有 Google 這種登入方式")
        XCTAssertTrue(app.element("sheet.merge").waitUntilGone(timeout: 5), "合併 sheet 沒有收起")
    }
}
