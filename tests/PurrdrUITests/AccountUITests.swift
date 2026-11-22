import XCTest

/// 帳號頁(#246、#409):右上角帳號鈕、Purrdr Plus 卡、未開通時通知與同步鎖住。
/// 預設未加入會員;`-uiTestingMember`／`-uiTestingPlusMember` 以假後台的會員啟動。
final class AccountUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 沒登入:帳號 sheet 先選「登入」或「加入會員」(#408),不出現登入鈕、步驟卡與帳號頁的區塊。
    @MainActor
    func testSignedOutAccountAsksSignInOrJoin() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitUntilExists(timeout: 10), "列表右上角沒有帳號鈕")
        XCTAssertEqual(account.label, "Account")
        account.tap()

        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "沒登入沒有顯示選擇頁")
        XCTAssertTrue(app.staticTexts["Purrdr Member"].exists)
        XCTAssertTrue(app.buttons["account.entry.signIn"].exists, "沒有「登入」")
        XCTAssertTrue(app.buttons["account.entry.join"].exists, "沒有「加入會員」")
        XCTAssertFalse(app.buttons["member.signIn.apple"].exists, "選擇前不該有登入鈕")
        XCTAssertTrue(app.staticTexts["Chat, terminal, and host management don’t need a member account."].exists)
        XCTAssertFalse(app.element("account.plusCard").exists, "沒登入不該有 Plus 卡")
        XCTAssertFalse(app.element("sheet.account").exists, "沒登入不該是帳號頁")
        XCTAssertFalse(app.staticTexts["Not a Member Yet"].exists)
    }

    /// 登入(#408):選「登入」→ Apple 登入 → 直接進帳號頁,不走加入步驟。
    @MainActor
    func testSignInGoesStraightToAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingSignUp"])
        app.openAccount()
        XCTAssertTrue(app.buttons["account.entry.signIn"].waitUntilExists(timeout: 10))
        app.buttons["account.entry.signIn"].tap()

        XCTAssertTrue(app.element("account.entry.signInPage").waitUntilExists(timeout: 5), "沒有登入頁")
        XCTAssertFalse(app.staticTexts["member.entry.step"].exists, "登入不標加入步驟")
        XCTAssertTrue(app.buttons["member.entry.back"].exists)
        app.buttons["member.signIn.apple"].tap()

        XCTAssertTrue(app.element("sheet.account").waitUntilExists(timeout: 10), "登入後沒有進帳號頁")
        XCTAssertFalse(app.element("account.join.paywall").exists, "登入不該走加入步驟")
        XCTAssertTrue(app.staticTexts["ray@example.com"].firstMatch.exists)
    }

    /// 登入頁與加入頁互相切換,返回回到選擇頁(#408)。
    @MainActor
    func testSwitchBetweenSignInAndJoin() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingSignUp"])
        app.openAccount()
        XCTAssertTrue(app.buttons["account.entry.signIn"].waitUntilExists(timeout: 10))
        app.buttons["account.entry.signIn"].tap()
        XCTAssertTrue(app.element("account.entry.signInPage").waitUntilExists(timeout: 5))
        app.buttons["account.entry.switch"].tap()
        XCTAssertTrue(app.element("account.entry.joinPage").waitUntilExists(timeout: 5), "沒切到加入頁")
        XCTAssertEqual(app.staticTexts["member.entry.step"].label, "Step 1 of 4")
        app.buttons["account.entry.switch"].tap()
        XCTAssertTrue(app.element("account.entry.signInPage").waitUntilExists(timeout: 5), "沒切回登入頁")
        app.buttons["member.entry.back"].tap()
        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 5), "返回沒回到選擇頁")
    }

    /// 登入保留(#406):後台連不上時仍是登入狀態,帳號頁說明「暫時連不上」,不是登入頁。
    @MainActor
    func testUnreachableBackendKeepsSignedIn() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMemberOffline"])
        app.openAccountSheet()

        XCTAssertTrue(app.element("account.connectionLimited").waitUntilExists(timeout: 10), "沒有「暫時連不上」說明")
        XCTAssertTrue(app.staticTexts["Can’t reach Purrdr for now. You’re still signed in."].exists)
        XCTAssertTrue(app.staticTexts["ray@example.com"].firstMatch.exists, "連不上時不顯示登入中的會員")
        XCTAssertTrue(app.buttons["account.connectionLimited.retry"].exists, "沒有再試一次")
        XCTAssertFalse(app.element("account.signedOut").exists, "連不上不該變成登入頁")
    }

    /// 帳號鈕在最右上角(HIG),新增聊天在它左邊。
    @MainActor
    func testAccountButtonIsRightmostAfterNewChat() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"]
        let newChat = app.buttons["toolbar.newChat"]
        XCTAssertTrue(account.waitUntilExists(timeout: 10))
        XCTAssertTrue(newChat.exists)

        XCTAssertGreaterThan(account.frame.minX, newChat.frame.maxX - 1, "帳號鈕不在新增聊天右邊")
        let rightmost = app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.map(\.frame.maxX).max() ?? 0
        XCTAssertEqual(account.frame.maxX, rightmost, accuracy: 1, "帳號鈕不是最右邊")
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

    /// 已開通:Plus 卡顯示來源與管理訂閱,沒有購買按鈕;通知(逐台)與主機同步開關在帳號頁,可開可關(#263、#409)。
    @MainActor
    func testPlusMemberCardAndTogglesStayOnAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        app.openAccountSheet()

        let status = app.element("account.plusCard.status")
        XCTAssertTrue(status.waitUntilExists(timeout: 10), "沒有 Plus 卡")
        XCTAssertTrue(status.label.contains("Active"), status.label)
        XCTAssertTrue(status.label.contains("App Store"), status.label)
        XCTAssertTrue(app.buttons["account.plusCard.manage"].exists, "App Store 訂閱沒有管理訂閱")
        XCTAssertFalse(app.buttons["account.plusCard.primary"].exists, "已開通不該有開通按鈕")
        XCTAssertFalse(app.buttons["account.plusCard.secondary"].exists, "已開通不該有恢復購買")

        let toggle = app.switches["account.push.5EED0000-0000-4000-8000-000000000001"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: toggle, search: .down, timeout: 10), "沒有主機的通知開關")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10), "開通知沒有先確認安裝外掛")
        install.tap()
        XCTAssertTrue(toggle.wait(for: NSPredicate(format: "value == %@", "Notifications On"), timeout: 10), "等待的條件沒有成立")

        // 仍可關閉那台主機的通知。
        toggle.tap()
        XCTAssertTrue(toggle.wait(for: NSPredicate(format: "value == %@", "Notifications Off"), timeout: 10), "等待的條件沒有成立")

        // 主機同步在「通知裝置」之後，要往下捲才進畫面。
        let hostSync = app.switches["settings.hostSync"]
        XCTAssertTrue(app.scrollIntoView(hostSync, search: .down), "沒有主機同步開關")
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

    @MainActor
    func testTraditionalChineseAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])
        app.openAccountSheet()

        XCTAssertTrue(app.navigationBars["帳號"].waitUntilExists(timeout: 5), "帳號頁標題不是繁體中文")
        XCTAssertTrue(app.staticTexts["尚未開通"].exists, "Plus 卡狀態不是繁體中文")
        XCTAssertEqual(app.buttons["account.plusCard.primary"].label, "開通 Purrdr Plus")
    }

    @MainActor
    func testTraditionalChineseSignedOutAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitUntilExists(timeout: 10))
        account.tap()

        // 沒登入先選「登入」或「加入會員」(#408)。
        XCTAssertTrue(app.navigationBars["帳號"].waitUntilExists(timeout: 5), "選擇頁標題不是繁體中文")
        XCTAssertTrue(app.buttons["account.entry.signIn"].exists)
        XCTAssertTrue(app.buttons["account.entry.signIn"].label.contains("登入"), app.buttons["account.entry.signIn"].label)
    }

    // MARK: - 輔助

}
