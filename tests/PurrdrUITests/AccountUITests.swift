import XCTest

/// 帳號頁(#246):右上角帳號鈕、「設定 Purrdr Plus」步驟卡、未開通時通知與同步鎖住。UI 測試沒有會員後台，一律是未加入會員。
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAccountButtonOpensSetupStepsAtJoin() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "列表右上角沒有帳號鈕")
        XCTAssertEqual(account.label, "Account")
        account.tap()

        XCTAssertTrue(element("sheet.account", in: app).waitForExistence(timeout: 10), "沒有開出帳號頁")
        XCTAssertTrue(app.staticTexts["Not a Member Yet"].exists)
        for step in ["join", "activate", "notifications", "sync"] {
            XCTAssertTrue(element("account.plusSetup.\(step)", in: app).exists, "步驟卡沒有 \(step)")
        }
        // 只有目前那一步(加入會員)有按鈕。
        XCTAssertEqual(app.buttons.matching(identifier: "account.plusSetup.action").count, 1)
        XCTAssertEqual(app.buttons["account.plusSetup.action"].label, "Join")
        XCTAssertEqual(element("account.plusSetup.join", in: app).value as? String, "Next Step")
        XCTAssertEqual(element("account.plusSetup.notifications", in: app).value as? String, "Not Yet")
    }

    /// 未開通時通知與同步不能開啟，畫面說明下一步。
    @MainActor
    func testLockedFeaturesExplainNextStep() {
        let app = XCUIApplication.launchUITesting()
        openAccount(in: app)

        let hint = element("account.lockedHint", in: app)
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "沒有說明通知與同步要先做什麼")
        XCTAssertTrue(hint.label.contains("Join as a member first"), hint.label)
        XCTAssertFalse(app.switches["settings.push"].exists, "未開通不該有通知開關")
        XCTAssertFalse(app.switches["settings.hostSync"].exists, "未開通不該有主機同步開關")
    }

    @MainActor
    func testJoinPushesSignInInsideAccountSheet() {
        let app = XCUIApplication.launchUITesting()
        openAccount(in: app)

        app.buttons["account.plusSetup.action"].tap()

        XCTAssertTrue(app.buttons["member.signIn.apple"].waitForExistence(timeout: 10), "沒有進入登入頁")
        // 同一個 sheet 內 push:返回帳號頁。
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("sheet.account", in: app).waitForExistence(timeout: 5), "沒有回到帳號頁")
    }

    @MainActor
    func testTraditionalChineseAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])
        openAccount(in: app)

        XCTAssertTrue(app.navigationBars["帳號"].waitForExistence(timeout: 5), "帳號頁標題不是繁體中文")
        XCTAssertTrue(app.staticTexts["設定 Purrdr Plus"].exists)
        XCTAssertEqual(app.buttons["account.plusSetup.action"].label, "加入")
    }

    // MARK: - 輔助

    @MainActor
    private func openAccount(in app: XCUIApplication) {
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "列表右上角沒有帳號鈕")
        account.tap()
        XCTAssertTrue(element("sheet.account", in: app).waitForExistence(timeout: 10), "沒有開出帳號頁")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
