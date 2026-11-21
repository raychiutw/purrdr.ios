import XCTest

/// 帳號頁(#246):右上角帳號鈕、「設定 Purrdr Plus」步驟卡、未開通時通知與同步鎖住。
/// 預設未加入會員;`-uiTestingMember`／`-uiTestingPlusMember` 以假後台的會員啟動。
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 沒登入:帳號 sheet 直接是登入頁(#328,原型 A),不出現步驟卡與帳號頁的區塊。
    @MainActor
    func testSignedOutAccountOpensSignInPage() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "列表右上角沒有帳號鈕")
        XCTAssertEqual(account.label, "Account")
        account.tap()

        XCTAssertTrue(element("account.signedOut", in: app).waitForExistence(timeout: 10), "沒登入沒有直接顯示登入頁")
        XCTAssertTrue(app.staticTexts["Sign In to Purrdr"].exists)
        XCTAssertTrue(app.buttons["member.signIn.apple"].exists, "沒有 Apple 登入鈕")
        XCTAssertTrue(app.buttons["member.signIn.google"].exists, "沒有 Google 登入鈕")
        XCTAssertTrue(app.staticTexts["Chat and terminal don’t need a member account."].exists)
        XCTAssertFalse(element("account.plusSetup", in: app).exists, "沒登入不該有步驟卡")
        XCTAssertFalse(element("sheet.account", in: app).exists, "沒登入不該是帳號頁")
        XCTAssertFalse(app.staticTexts["Not a Member Yet"].exists)
    }

    /// 帳號鈕在最右上角(HIG),「⋯」在它左邊。
    @MainActor
    func testAccountButtonIsRightmostAfterMore() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"]
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        XCTAssertTrue(more.exists)

        XCTAssertGreaterThan(account.frame.minX, more.frame.maxX - 1, "帳號鈕不在「⋯」右邊")
        let rightmost = app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.map(\.frame.maxX).max() ?? 0
        XCTAssertEqual(account.frame.maxX, rightmost, accuracy: 1, "帳號鈕不是最右邊")
    }

    /// 已加入會員、未開通：顯示會員 email,目前步驟是開通，點了推入付費牆。
    @MainActor
    func testMemberWithoutPlusActivatesFromPaywall() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        openAccount(in: app)

        XCTAssertTrue(app.staticTexts["ray@example.com"].waitForExistence(timeout: 10), "沒有顯示會員")
        let action = app.buttons["account.plusSetup.action"]
        expectation(for: NSPredicate(format: "label == %@", "Activate"), evaluatedWith: action)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(element("account.plusSetup.join", in: app).value as? String, "Done")
        action.tap()

        XCTAssertTrue(element("plus.benefits", in: app).waitForExistence(timeout: 10), "沒有推入付費牆")
    }

    /// 開通後開通知與主機同步：四步完成後步驟卡收成「Purrdr Plus・已開通」一列，通知(逐台)與主機同步開關仍在帳號頁(#263)。
    @MainActor
    func testPlusMemberCompletesSetupAndTogglesStayOnAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        openAccount(in: app)

        let action = app.buttons["account.plusSetup.action"]
        expectation(for: NSPredicate(format: "label == %@", "Choose Hosts"), evaluatedWith: action)
        waitForExpectations(timeout: 10)
        action.tap()
        let toggle = app.switches["account.push.5EED0000-0000-4000-8000-000000000001"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "沒有主機的通知開關")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10), "開通知沒有先確認安裝外掛")
        install.tap()

        // 「選擇主機」把列表捲到「通知」,步驟卡可能捲出畫面(lazy List 不在樹裡):捲回頂端。
        let sync = element("account.plusSetup.sync", in: app)
        for _ in 0..<6 where !(sync.exists && sync.isHittable) {
            element("sheet.account", in: app).swipeDown()
        }
        expectation(for: NSPredicate(format: "value == %@", "Next Step"), evaluatedWith: sync)
        waitForExpectations(timeout: 10)
        app.buttons["account.plusSetup.action"].tap()

        let collapsed = element("member.plus", in: app)
        XCTAssertTrue(collapsed.waitForExistence(timeout: 10), "四步完成後沒有收成一列")
        XCTAssertFalse(element("account.plusSetup", in: app).exists, "四步完成後仍顯示步驟卡")
        XCTAssertTrue(app.staticTexts["Purrdr Plus · Active"].exists)
        XCTAssertEqual(toggle.value as? String, "Notifications On")

        // 收合後仍可關閉那台主機的通知。
        toggle.tap()
        expectation(for: NSPredicate(format: "value == %@", "Notifications Off"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)

        // 主機同步在「通知裝置」之後，要往下捲才進畫面。
        let hostSync = app.switches["settings.hostSync"]
        XCTAssertTrue(scrollTo(hostSync, in: app), "收合後沒有主機同步開關")
        XCTAssertEqual(hostSync.value as? String, "1")
    }

    /// 已登入、未開通時通知與同步不能開啟，畫面說明下一步。
    @MainActor
    func testLockedFeaturesExplainNextStep() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        openAccount(in: app)

        let hint = element("account.lockedHint", in: app)
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "沒有說明通知與同步要先做什麼")
        XCTAssertTrue(hint.label.contains("Activate it next"), hint.label)
        XCTAssertFalse(app.switches["account.push.demo"].exists, "未開通不該有通知開關")
        XCTAssertFalse(app.switches["settings.hostSync"].exists, "未開通不該有主機同步開關")
    }

    @MainActor
    func testTraditionalChineseAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])
        openAccount(in: app)

        XCTAssertTrue(app.navigationBars["帳號"].waitForExistence(timeout: 5), "帳號頁標題不是繁體中文")
        XCTAssertTrue(app.staticTexts["設定 Purrdr Plus"].exists)
        XCTAssertEqual(app.buttons["account.plusSetup.action"].label, "開通")
    }

    @MainActor
    func testTraditionalChineseSignedOutAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()

        XCTAssertTrue(app.navigationBars["登入"].waitForExistence(timeout: 5), "登入頁標題不是繁體中文")
        XCTAssertTrue(app.staticTexts["登入 Purrdr"].exists)
    }

    // MARK: - 輔助

    @MainActor
    private func openAccount(in app: XCUIApplication) {
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "列表右上角沒有帳號鈕")
        account.tap()
        XCTAssertTrue(element("sheet.account", in: app).waitForExistence(timeout: 10), "沒有開出帳號頁")
    }

    /// 往下捲到元素出現(帳號頁比畫面長)。
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
