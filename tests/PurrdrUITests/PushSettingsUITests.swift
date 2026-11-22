import XCTest

/// 帳號頁的「通知」區塊(#29、#246;#263 起每台主機一個開關)。UI 測試不連網路：`-uiTestingPlusMember` 以假後台的已開通會員啟動，
/// 通知權限當作已允許;`-seedHost` 的主機以 Demo 主機回應，外掛安裝只在記憶體。
final class PushSettingsUITests: XCTestCase {
    static let seededHost = "5EED0000-0000-4000-8000-000000000001"
    static let unreachableHost = "5EED0000-0000-4000-8000-000000000002"
    static let httpsHost = "5EED0000-0000-4000-8000-000000000003"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 步驟卡「選擇主機」捲到「通知」區塊;開那台主機先確認(對話框寫主機名稱),確認後步驟完成並列出主機名稱。
    @MainActor
    func testChooseHostsScrollsToNotificationsAndTurnsOnHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        app.openAccountSheet()

        let notifications = app.element("account.plusSetup.notifications")
        XCTAssertTrue(notifications.waitUntilExists(timeout: 10))
        notifications.expectValue("Next Step")
        let action = app.buttons["account.plusSetup.action"]
        XCTAssertEqual(action.label, "Choose Hosts")
        action.tap()

        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "沒有主機的通知開關")
        XCTAssertTrue(toggle.isHittable, "沒有捲到「通知」區塊")
        XCTAssertEqual(toggle.label, "Studio Mac")
        XCTAssertEqual(toggle.value as? String, "Notifications Off")
        toggle.tap()

        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10), "沒有先確認安裝外掛")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("Studio Mac"), "確認對話框沒寫主機名稱:\(app.alerts.firstMatch.label)")
        install.tap()

        toggle.expectValue("Notifications On")
        // 「選擇主機」把列表捲到「通知」,步驟卡捲出畫面(lazy List 不在樹裡):捲回頂端再看步驟。
        XCTAssertTrue(app.scrollSheet("sheet.account", to: notifications, search: .up, limit: 6), "捲回頂端後沒有步驟卡")
        notifications.expectValue("Done")
        XCTAssertTrue(notifications.label.contains("Studio Mac"), "步驟沒有列出開啟的主機:\(notifications.label)")
        app.element("account.plusSetup.sync").expectValue("Next Step")
    }

    /// 通知開著的主機有「傳送測試通知」(#328);通知沒開的主機沒有。成功以提示說明。
    @MainActor
    func testSendTestNotificationReportsSuccess() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        app.openAccountSheet()
        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: toggle, search: .down, timeout: 10))
        let test = app.buttons["account.push.\(Self.seededHost).test"]
        XCTAssertFalse(test.exists, "通知沒開不該有傳送測試通知")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10))
        install.tap()
        toggle.expectValue("Notifications On")

        XCTAssertTrue(app.scrollSheet("sheet.account", to: test, search: .down, timeout: 10), "通知開著沒有傳送測試通知")
        test.tap()
        XCTAssertTrue(app.alerts["Test Notification Sent"].waitUntilExists(timeout: 5), "沒有成功提示")
        app.alerts.buttons["OK"].tap()
    }

    /// 測試通知失敗時提示說明原因。
    @MainActor
    func testSendTestNotificationReportsFailure() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost", "-uiTestingPushTestFails"])
        app.openAccountSheet()
        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: toggle, search: .down, timeout: 10))
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10))
        install.tap()
        toggle.expectValue("Notifications On")

        let test = app.buttons["account.push.\(Self.seededHost).test"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: test, search: .down, timeout: 10))
        test.tap()
        let alert = app.alerts["Couldn’t Send Test Notification"]
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有失敗提示")
        XCTAssertTrue(alert.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("Couldn’t send the test notification") }, "沒有說明原因")
        alert.buttons["OK"].tap()
    }

    /// 開著通知的主機可展開選種類(#292):預設「需要你」「完成」都開(SSH 主機沒有「主機服務」);關掉「完成」後只剩「需要你」,最後一個不能關。
    @MainActor
    func testChooseNotificationKindsPerHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        app.openAccountSheet()

        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: toggle, search: .down, timeout: 10), "沒有主機的通知開關")
        XCTAssertFalse(app.element("account.push.\(Self.seededHost).kinds").exists, "未開啟的主機不該有種類")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10))
        install.tap()
        toggle.expectValue("Notifications On")

        let kinds = app.element("account.push.\(Self.seededHost).kinds")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: kinds, search: .down, timeout: 10), "開啟後沒有可展開的通知種類")
        kinds.tap()
        let blocked = app.switches["account.push.\(Self.seededHost).kind.blocked"]
        let done = app.switches["account.push.\(Self.seededHost).kind.done"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: done, search: .down, timeout: 10), "展開後沒有「完成」")
        XCTAssertEqual(blocked.label, "Needs You")
        XCTAssertEqual(done.label, "Finished")
        blocked.expectValue("1")
        done.expectValue("1")
        // 主機服務通知(#293)只有 HTTPS 主機能選;這台是 SSH 主機。
        XCTAssertFalse(app.switches["account.push.\(Self.seededHost).kind.host_service"].exists, "SSH 主機不該有「主機服務」種類")

        done.switches.firstMatch.tap()
        done.expectValue("0")
        blocked.expectValue("1")
        XCTAssertFalse(blocked.isEnabled, "最後一個種類不該能關")
    }

    /// Demo 主機與還不支援的 HTTPS 主機寫出原因，開關不能點;footer 標示 Windows 主機盡力而為。
    @MainActor
    func testNotificationsExplainHostsThatCannotNotify() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedUnpairedHTTPSHost", "-selectDemo"])
        app.openAccountSheet()

        let demo = app.switches["account.push.demo"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: demo, search: .down, timeout: 10), "沒有 Demo 主機的通知列")
        XCTAssertFalse(demo.isEnabled)
        XCTAssertEqual(app.element("account.push.demo.status").label, "The demo host can’t send notifications.")

        let https = app.switches["account.push.\(Self.httpsHost)"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: https, search: .down, timeout: 10), "沒有 HTTPS 主機的通知列")
        XCTAssertFalse(https.isEnabled)
        // 還沒配對的 HTTPS 主機說明要先配對(#295);主機服務太舊的說明由 HostServiceUpdateTests 涵蓋。
        let pair = app.element("account.push.\(Self.httpsHost).status")
        XCTAssertEqual(pair.label, "Pair This Host First")
        XCTAssertTrue(pair.isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "may be delayed")).firstMatch.exists)
        // 沒有跳系統的通知權限對話框。
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    /// 還沒配對的 HTTPS 主機(#295):點通知列開與主機頁相同的配對;配對存好回到帳號頁，開關就能點。
    @MainActor
    func testUnpairedHTTPSHostRowOpensPairing() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedUnpairedHTTPSHost", "-selectDemo"])
        app.openAccountSheet()

        let https = app.switches["account.push.\(Self.httpsHost)"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: https, search: .down, timeout: 10), "沒有 HTTPS 主機的通知列")
        XCTAssertFalse(https.isEnabled)
        app.element("account.push.\(Self.httpsHost).status").tap()

        // 直接到引導的配對那一步:位址已帶入，輸入配對碼、測試通過後加入。
        XCTAssertTrue(app.textFields["guide.field.pairAddress"].waitUntilExists(timeout: 5), "沒有開配對")
        let code = app.textFields["guide.field.pairingCode"]
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        app.buttons["guide.next"].tap()
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有連上")
        save.tap()
        let done = app.buttons["guide.done"]
        XCTAssertTrue(done.waitUntilExists(timeout: 5))
        done.tap()

        XCTAssertTrue(app.scrollSheet("sheet.account", to: https, search: .down, timeout: 10), "沒有回到帳號頁的通知列")
        XCTAssertTrue(https.wait(timeout: 10) { $0.isEnabled }, "配對後開關仍不能點")
    }

    /// 連不上的主機：開啟失敗寫出原因與「點開關重試」,開關仍可點。
    @MainActor
    func testFailedTurnOnExplainsAndCanRetry() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedUnreachableHost"])
        app.openAccountSheet()

        let toggle = app.switches["account.push.\(Self.unreachableHost)"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: toggle, search: .down, timeout: 10), "沒有主機的通知開關")
        toggle.tap()

        let status = app.element("account.push.\(Self.unreachableHost).status")
        XCTAssertTrue(status.waitForLabel(containing: "Tap the switch to try again.", timeout: 40), "失敗沒有說明:\(status.label)")
        XCTAssertEqual(toggle.value as? String, "Notifications Off")
        XCTAssertTrue(toggle.isEnabled, "失敗後不能點開關重試")
    }

    /// 未開通時通知不能開啟：步驟卡上沒有通知的按鈕，也沒有主機的通知開關。
    @MainActor
    func testCannotTurnOnWithoutPlus() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember", "-seedHost"])
        app.openAccountSheet()

        let activate = app.element("account.plusSetup.activate")
        XCTAssertTrue(activate.waitUntilExists(timeout: 10))
        activate.expectValue("Next Step")
        XCTAssertEqual(app.buttons.matching(identifier: "account.plusSetup.action").count, 1)
        XCTAssertEqual(app.buttons["account.plusSetup.action"].label, "Activate")
        XCTAssertEqual(app.element("account.plusSetup.notifications").value as? String, "Not Yet")
        XCTAssertTrue(app.element("account.lockedHint").label.contains("Activate it next"))
        XCTAssertFalse(app.switches["account.push.\(Self.seededHost)"].exists)
    }

    // MARK: - 輔助

}
