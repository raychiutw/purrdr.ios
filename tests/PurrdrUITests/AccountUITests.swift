import XCTest

/// 帳號頁(#246、#409):右上角帳號鈕、Purrdr Plus 卡、未開通時通知與同步鎖住。
/// 預設未加入會員;`-uiTestingMember`／`-uiTestingPlusMember` 以假後台的會員啟動。
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 已加入會員、未開通:顯示會員 email 與登入方式,Plus 卡主按鈕開通,點了推入付費牆(#409)。
    @MainActor
    func testMemberWithoutPlusActivatesFromPaywall() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        app.openAccountSheet()

        XCTAssertTrue(app.staticTexts["ray@example.com"].firstMatch.waitUntilExists(timeout: 10), "沒有顯示會員")
        XCTAssertTrue(app.staticTexts["Apple"].exists, "沒有顯示登入方式")
        let action = app.buttons["account.plusCard.primary"]
        XCTAssertTrue(action.waitUntilExists(timeout: 10), "沒有開通按鈕")
        XCTAssertEqual(action.label, "Activate Purrdr Plus")
        XCTAssertTrue(app.buttons["account.plusCard.secondary"].exists, "沒有恢復購買")
        action.tap()

        XCTAssertTrue(app.element("plus.benefits").waitUntilExists(timeout: 10), "沒有推入付費牆")
    }

    /// 已登入、未開通時通知與同步鎖定:列仍可點,說明原因與下一步,沒有開關(#409)。
    @MainActor
    func testLockedFeaturesExplainNextStep() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        app.openAccountSheet()

        let locked = app.element("account.locked.hostSync")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: locked, search: .down, timeout: 10), "沒有鎖定的主機同步列")
        XCTAssertTrue((locked.value as? String)?.contains("Needs Purrdr Plus") == true, "鎖定列沒有寫需要 Purrdr Plus:\(String(describing: locked.value))")
        XCTAssertTrue(app.element("account.locked.notifications").exists, "沒有鎖定的通知列")
        XCTAssertFalse(app.switches["account.push.demo"].exists, "未開通不該有通知開關")
        XCTAssertFalse(app.switches["settings.hostSync"].exists, "未開通不該有主機同步開關")

        locked.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitUntilExists(timeout: 5), "點鎖定列沒有說明")
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Activate it from'")).firstMatch.exists)
        app.buttons["account.locked.openPlus"].firstMatch.tap()
        XCTAssertTrue(app.element("plus.benefits").waitUntilExists(timeout: 10), "說明裡的「Purrdr Plus」沒有開付費牆")
    }

    // MARK: - 輔助

}
