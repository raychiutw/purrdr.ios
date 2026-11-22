import XCTest

/// 帳號頁的「通知裝置」區塊(#266)。`-uiTestingPlusMember` 的假後台一開始有「Studio iPad」與一支舊版 app 的未命名裝置;
/// 這支裝置開了主機(`-seedHost`,Demo 主機回應安裝)才列出並標「This Device」。
final class PushDevicesUITests: XCTestCase {
    static let seededHost = "5EED0000-0000-4000-8000-000000000001"
    static let thisDevice = "5eed0000-0000-4000-8000-0000000000d1"
    static let studioIPad = "5eed0000-0000-4000-8000-0000000000d2"
    static let legacyDevice = "legacy-5eed00000000000000000000000000d3"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 列出其他裝置(名稱、型號、主機數);舊版 app 的裝置顯示「Unnamed Device」。改名後清單換成新名稱。
    @MainActor
    func testListsDevicesAndRenames() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        app.openAccountSheet()

        openPushDevices(app)
        let ipad = app.element("account.pushDevice.\(Self.studioIPad)")
        XCTAssertTrue(ipad.waitUntilExists(timeout: 10), "沒有 Studio iPad 的列")
        XCTAssertTrue(ipad.label.contains("Studio iPad"), ipad.label)
        XCTAssertTrue(ipad.label.contains("Hosts: 2"), ipad.label)
        XCTAssertFalse(ipad.label.contains("This Device"), ipad.label)
        let legacy = app.element("account.pushDevice.\(Self.legacyDevice)")
        XCTAssertTrue(legacy.waitUntilExists(timeout: 10), "沒有舊版 app 的裝置列")
        XCTAssertTrue(legacy.label.contains("Unnamed Device"), legacy.label)

        app.buttons["account.pushDevice.\(Self.studioIPad)"].tap()
        app.buttons["Rename…"].firstMatch.tap()
        // SwiftUI 不把 identifier 帶到 alert 裡的 TextField。
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "沒有改名欄位")
        field.clearAndType("Desk iPad")
        app.alerts.buttons["account.pushDevices.save"].firstMatch.tap()

        ipad.expectLabel(containing: "Desk iPad")
    }

    /// 遠端關閉別支裝置：先確認，確認後從清單消失。
    @MainActor
    func testTurnsOffAnotherDevice() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        app.openAccountSheet()

        openPushDevices(app)
        let ipad = app.element("account.pushDevice.\(Self.studioIPad)")
        XCTAssertTrue(ipad.waitUntilExists(timeout: 10), "沒有 Studio iPad 的列")
        app.buttons["account.pushDevice.\(Self.studioIPad)"].tap()
        app.buttons["Turn Off Notifications…"].firstMatch.tap()

        let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有先確認")
        confirm.tap()

        XCTAssertTrue(ipad.waitUntilGone(timeout: 10), "關閉後仍在清單")
    }

    /// 訂閱到期(已登入、沒有 Purrdr Plus):仍列出裝置並可遠端關閉遺失的裝置，但不能改名。
    @MainActor
    func testWithoutPlusCanStillTurnOffDevices() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        app.openAccountSheet()

        openPushDevices(app)
        let ipad = app.element("account.pushDevice.\(Self.studioIPad)")
        XCTAssertTrue(ipad.waitUntilExists(timeout: 10), "沒有 Plus 時沒有列出裝置")
        app.buttons["account.pushDevice.\(Self.studioIPad)"].tap()
        XCTAssertFalse(app.buttons["Rename…"].firstMatch.waitUntilExists(timeout: 2), "沒有 Plus 仍能改名")
        app.buttons["Turn Off Notifications…"].firstMatch.tap()
        let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有先確認")
        confirm.tap()

        XCTAssertTrue(ipad.waitUntilGone(timeout: 10), "關閉後仍在清單")
    }

    /// 這支裝置開了主機後列出並標「This Device」;從這裡關閉後，「通知」區塊的主機回到關閉。
    @MainActor
    func testTurningOffThisDeviceTurnsHostsOff() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        app.openAccountSheet()

        app.openAccountNotifications()
        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "沒有主機的通知開關")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitUntilExists(timeout: 10))
        install.tap()
        toggle.expectValue("Notifications On")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openPushDevices(app)
        let thisDevice = app.element("account.pushDevice.\(Self.thisDevice)")
        XCTAssertTrue(thisDevice.waitUntilExists(timeout: 10), "開了主機後沒有列出這支裝置")
        thisDevice.expectLabel(containing: "This Device")
        app.buttons["account.pushDevice.\(Self.thisDevice)"].tap()
        app.buttons["Turn Off Notifications…"].firstMatch.tap()
        let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5))
        confirm.tap()

        XCTAssertTrue(thisDevice.waitUntilGone(timeout: 10), "關閉後仍在清單")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.openAccountNotifications()
        toggle.expectValue("Notifications Off")
    }

    // MARK: - 輔助

    /// 帳號頁捲到「Notification Devices」入口並點開子頁(設計稿第 28 組)。
    @MainActor
    private func openPushDevices(_ app: XCUIApplication) {
        let link = app.element("member.pushDevices")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: link, search: .down, timeout: 10), "帳號頁沒有通知裝置入口")
        link.tap()
        XCTAssertTrue(app.element("account.pushDevices").waitUntilExists(timeout: 10), "沒有進到通知裝置子頁")
    }

}
