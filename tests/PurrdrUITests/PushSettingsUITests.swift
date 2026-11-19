import XCTest

/// 推播開關(#29;#246 起在帳號頁)。UI 測試不連網路：`-uiTestingPlusMember` 以假後台的已開通會員啟動，
/// 通知權限當作已允許;`-seedHost` 的主機以 Demo 主機回應，外掛安裝只在記憶體。
final class PushSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 開通後：帳號頁步驟卡的「開啟」先確認安裝外掛，確認後通知那一步完成。
    @MainActor
    func testTurningOnFromAccountAsksToInstallPluginThenCompletesStep() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        openAccount(app)

        let notifications = element("account.plusSetup.notifications", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 10))
        expectValue("Next Step", of: notifications)
        app.buttons["account.plusSetup.action"].tap()

        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10), "沒有先確認安裝外掛")
        install.tap()

        expectValue("Done", of: notifications)
        expectValue("Next Step", of: element("account.plusSetup.sync", in: app))
    }

    /// 開通後的 Purrdr Plus 頁有通知開關，並標示 Windows 主機盡力而為。
    @MainActor
    func testPushToggleIsInPlusPageAndMentionsWindowsBestEffort() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        openAccount(app)

        let plus = element("member.plus", in: app)
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "開通後帳號頁沒有 Purrdr Plus 列")
        plus.tap()

        let toggle = app.switches["settings.push"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "best-effort")).firstMatch.exists)
    }

    @MainActor
    func testTurningOnWithDemoHostExplainsWithoutPermissionPrompt() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        openAccount(app)

        let notifications = element("account.plusSetup.notifications", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 10))
        expectValue("Next Step", of: notifications)
        app.buttons["account.plusSetup.action"].tap()

        XCTAssertTrue(element("settings.push.problem", in: app).waitForExistence(timeout: 5), "Demo 主機沒有說明要先選自己的主機")
        XCTAssertEqual(notifications.value as? String, "Next Step")
        // 沒有跳系統的通知權限對話框。
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    /// 未開通時通知不能開啟：步驟卡上沒有通知的按鈕，畫面說明下一步。
    @MainActor
    func testCannotTurnOnWithoutPlus() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember", "-seedHost"])
        openAccount(app)

        let activate = element("account.plusSetup.activate", in: app)
        XCTAssertTrue(activate.waitForExistence(timeout: 10))
        expectValue("Next Step", of: activate)
        XCTAssertEqual(app.buttons.matching(identifier: "account.plusSetup.action").count, 1)
        XCTAssertEqual(app.buttons["account.plusSetup.action"].label, "Activate")
        XCTAssertEqual(element("account.plusSetup.notifications", in: app).value as? String, "Not Yet")
        XCTAssertTrue(element("account.lockedHint", in: app).label.contains("Activate it next"))
        XCTAssertFalse(app.switches["settings.push"].exists)
    }

    // MARK: - 輔助

    @MainActor
    private func openAccount(_ app: XCUIApplication) {
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()
        XCTAssertTrue(element("sheet.account", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 步驟狀態跟著會員與訂閱讀回(非同步)更新。
    @MainActor
    private func expectValue(_ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10)
        XCTAssertEqual(result, .completed, "\(element.identifier) 不是「\(value)」:\(String(describing: element.value))", file: file, line: line)
    }
}
