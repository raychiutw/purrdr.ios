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
        openAccount(app)

        let notifications = element("account.plusSetup.notifications", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 10))
        expectValue("Next Step", of: notifications)
        let action = app.buttons["account.plusSetup.action"]
        XCTAssertEqual(action.label, "Choose Hosts")
        action.tap()

        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "沒有主機的通知開關")
        XCTAssertTrue(toggle.isHittable, "沒有捲到「通知」區塊")
        XCTAssertEqual(toggle.label, "Studio Mac")
        XCTAssertEqual(toggle.value as? String, "Notifications Off")
        toggle.tap()

        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10), "沒有先確認安裝外掛")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("Studio Mac"), "確認對話框沒寫主機名稱:\(app.alerts.firstMatch.label)")
        install.tap()

        expectValue("Notifications On", of: toggle)
        // 「選擇主機」把列表捲到「通知」,步驟卡捲出畫面(lazy List 不在樹裡):捲回頂端再看步驟。
        XCTAssertTrue(revealAbove(notifications, in: app), "捲回頂端後沒有步驟卡")
        expectValue("Done", of: notifications)
        XCTAssertTrue(notifications.label.contains("Studio Mac"), "步驟沒有列出開啟的主機:\(notifications.label)")
        expectValue("Next Step", of: element("account.plusSetup.sync", in: app))
    }

    /// 開著通知的主機可展開選種類(#292):預設「需要你」「完成」都開(SSH 主機沒有「主機服務」);關掉「完成」後只剩「需要你」,最後一個不能關。
    @MainActor
    func testChooseNotificationKindsPerHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        openAccount(app)

        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(reveal(toggle, in: app), "沒有主機的通知開關")
        XCTAssertFalse(element("account.push.\(Self.seededHost).kinds", in: app).exists, "未開啟的主機不該有種類")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        install.tap()
        expectValue("Notifications On", of: toggle)

        let kinds = element("account.push.\(Self.seededHost).kinds", in: app)
        XCTAssertTrue(reveal(kinds, in: app), "開啟後沒有可展開的通知種類")
        kinds.tap()
        let blocked = app.switches["account.push.\(Self.seededHost).kind.blocked"]
        let done = app.switches["account.push.\(Self.seededHost).kind.done"]
        XCTAssertTrue(reveal(done, in: app), "展開後沒有「完成」")
        XCTAssertEqual(blocked.label, "Needs You")
        XCTAssertEqual(done.label, "Finished")
        expectValue("1", of: blocked)
        expectValue("1", of: done)
        // 主機服務通知(#293)只有 HTTPS 主機能選;這台是 SSH 主機。
        XCTAssertFalse(app.switches["account.push.\(Self.seededHost).kind.host_service"].exists, "SSH 主機不該有「主機服務」種類")

        done.switches.firstMatch.tap()
        expectValue("0", of: done)
        expectValue("1", of: blocked)
        XCTAssertFalse(blocked.isEnabled, "最後一個種類不該能關")
    }

    /// Demo 主機與還不支援的 HTTPS 主機寫出原因，開關不能點;footer 標示 Windows 主機盡力而為。
    @MainActor
    func testNotificationsExplainHostsThatCannotNotify() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedUnpairedHTTPSHost", "-selectDemo"])
        openAccount(app)

        let demo = app.switches["account.push.demo"]
        XCTAssertTrue(reveal(demo, in: app), "沒有 Demo 主機的通知列")
        XCTAssertFalse(demo.isEnabled)
        XCTAssertEqual(element("account.push.demo.status", in: app).label, "The demo host can’t send notifications.")

        let https = app.switches["account.push.\(Self.httpsHost)"]
        XCTAssertTrue(reveal(https, in: app), "沒有 HTTPS 主機的通知列")
        XCTAssertFalse(https.isEnabled)
        // 還沒配對的 HTTPS 主機沒有連線可裝外掛;主機服務太舊的說明由 HostServiceUpdateTests 涵蓋。
        XCTAssertEqual(element("account.push.\(Self.httpsHost).status", in: app).label, "This host can’t send notifications.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "best-effort")).firstMatch.exists)
        // 沒有跳系統的通知權限對話框。
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    /// 連不上的主機：開啟失敗寫出原因與「點開關重試」,開關仍可點。
    @MainActor
    func testFailedTurnOnExplainsAndCanRetry() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedUnreachableHost"])
        openAccount(app)

        let toggle = app.switches["account.push.\(Self.unreachableHost)"]
        XCTAssertTrue(reveal(toggle, in: app), "沒有主機的通知開關")
        toggle.tap()

        let status = element("account.push.\(Self.unreachableHost).status", in: app)
        let failed = NSPredicate(format: "label CONTAINS %@", "Tap the switch to try again.")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: failed, object: status)], timeout: 40)
        XCTAssertEqual(result, .completed, "失敗沒有說明:\(status.label)")
        XCTAssertEqual(toggle.value as? String, "Notifications Off")
        XCTAssertTrue(toggle.isEnabled, "失敗後不能點開關重試")
    }

    /// 未開通時通知不能開啟：步驟卡上沒有通知的按鈕，也沒有主機的通知開關。
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
        XCTAssertFalse(app.switches["account.push.\(Self.seededHost)"].exists)
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

    /// 帳號頁是 lazy 的 List:往上捲到元素出現。
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        if target.waitForExistence(timeout: 10), target.isHittable { return true }
        let list = element("sheet.account", in: app)
        for _ in 0..<6 where !(target.exists && target.isHittable) {
            list.swipeUp()
        }
        return target.exists && target.isHittable
    }

    /// 往下拉(列表往回捲)到元素出現。
    @MainActor
    private func revealAbove(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = element("sheet.account", in: app)
        for _ in 0..<6 where !(target.exists && target.isHittable) {
            list.swipeDown()
        }
        return target.exists && target.isHittable
    }

    /// 狀態跟著會員、訂閱讀回與主機安裝(非同步)更新。
    @MainActor
    private func expectValue(_ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10)
        XCTAssertEqual(result, .completed, "\(element.identifier) 不是「\(value)」:\(String(describing: element.value))", file: file, line: line)
    }
}
