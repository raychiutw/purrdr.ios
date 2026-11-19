import XCTest

/// 帳號頁(#246):右上角帳號鈕、「設定 Purrdr Plus」步驟卡、未開通時通知與同步鎖住。
/// 預設未加入會員;`-uiTestingMember`／`-uiTestingPlusMember` 以假後台的會員啟動。
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

    /// 開通後開主機同步：通知、同步都完成後，步驟卡收成「Purrdr Plus・已開通」一列，點進去兩個開關都開著。
    @MainActor
    func testPlusMemberTurnsOnSyncAndCardCollapses() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        openAccount(in: app)

        let action = app.buttons["account.plusSetup.action"]
        expectation(for: NSPredicate(format: "label == %@", "Turn On"), evaluatedWith: action)
        waitForExpectations(timeout: 10)
        action.tap()
        let install = app.alerts.buttons["settings.push.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), "開通知沒有先確認安裝外掛")
        install.tap()

        let sync = element("account.plusSetup.sync", in: app)
        expectation(for: NSPredicate(format: "value == %@", "Next Step"), evaluatedWith: sync)
        waitForExpectations(timeout: 10)
        app.buttons["account.plusSetup.action"].tap()

        let collapsed = element("member.plus", in: app)
        XCTAssertTrue(collapsed.waitForExistence(timeout: 10), "四步完成後沒有收成一列")
        XCTAssertFalse(element("account.plusSetup", in: app).exists, "四步完成後仍顯示步驟卡")
        XCTAssertTrue(app.staticTexts["Purrdr Plus · Active"].exists)
        collapsed.tap()
        XCTAssertEqual(app.switches["settings.push"].value as? String, "1")
        XCTAssertEqual(app.switches["settings.hostSync"].value as? String, "1")
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
