import XCTest

/// 帳號頁「登入方式」子頁與合併確認(#410,設計稿第 28 組)。只驗行為與文字,不驗版面像素。
/// 假後台旗標:`-uiTestingLinkMerge`(新增 Google 時發現已屬另一個會員)、`-uiTestingLinkMergeBlocked`(兩邊都有有效訂閱)。
final class SignInMethodsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 開帳號頁、推入「登入方式」。
    @MainActor
    private func openSignInMethods(_ app: XCUIApplication) {
        app.openAccountSheet()
        let row = app.element("member.signInMethods")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: row, search: .down, timeout: 10), "帳號頁沒有登入方式")
        row.tap()
        XCTAssertTrue(app.element("member.identity.apple").waitUntilExists(timeout: 10), "沒有開出登入方式")
    }

    /// 發現已屬另一個會員:出合併確認頁,兩邊摘要都在;確認後合併、回到登入方式有兩種。
    @MainActor
    func testLinkFindsAnotherMemberAndMerges() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingLinkMerge"])
        openSignInMethods(app)

        app.buttons["member.signIn.google"].tap()

        XCTAssertTrue(app.element("sheet.merge").waitUntilExists(timeout: 10), "沒有開出合併確認")
        XCTAssertTrue(app.element("member.merge.current").exists)
        XCTAssertTrue(app.element("member.merge.other").exists)
        app.assertModalToolbar(close: "member.merge.cancel", confirm: "member.merge.confirm")
        let confirm = app.buttons["member.merge.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(app.element("member.identity.google").waitUntilExists(timeout: 10), "合併後應該有 Google 這種登入方式")
        XCTAssertFalse(app.element("sheet.merge").exists)
    }

}
