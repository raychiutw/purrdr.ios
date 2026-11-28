import XCTest

/// 從舊版升級(#414):舊的更新權杖被後台拒絕,帳號頁提示登入已失效、要重新登入一次;
/// 重新登入後帳號頁顯示升級合併留下的待處理訂閱提示。只驗行為,不驗版面。
final class AccountUpgradeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testUpgradeAsksForOneSignInThenShowsPendingReview() {
        let app = XCUIApplication.launchUITesting(flags: [.uiTestingUpgradedMember])
        app.openAccount()

        // 舊的更新權杖被拒絕:提示登入已失效,回到選擇頁(不是已登入的帳號頁)。
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 10), "沒有提示登入已失效")
        XCTAssertTrue(alert.staticTexts["Signed Out"].exists, alert.debugDescription)
        alert.buttons["OK"].tap()
        let signIn = app.buttons["account.entry.signIn"].firstMatch
        XCTAssertTrue(signIn.waitUntilExists(timeout: 10), "沒有回到登入或加入的選擇頁")

        // 重新登入一次:帳號頁顯示升級合併後待處理的訂閱。
        signIn.tap()
        let apple = app.buttons["member.signIn.apple"].firstMatch
        XCTAssertTrue(apple.waitUntilExists(timeout: 10), "沒有登入頁")
        apple.tap()
        XCTAssertTrue(app.element("sheet.account").waitUntilExists(timeout: 10), "重新登入後沒有進帳號頁")
        let notice = app.element("account.pendingReview")
        XCTAssertTrue(notice.waitUntilExists(timeout: 10), "重新登入後沒有待處理提示\n\(app.debugDescription)")
        XCTAssertFalse(app.element("account.signedOut").exists)
    }
}
