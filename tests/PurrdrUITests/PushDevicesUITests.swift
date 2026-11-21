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
        openAccount(app)

        let ipad = element("account.pushDevice.\(Self.studioIPad)", in: app)
        XCTAssertTrue(reveal(ipad, in: app), "沒有 Studio iPad 的列")
        XCTAssertTrue(ipad.label.contains("Studio iPad"), ipad.label)
        XCTAssertTrue(ipad.label.contains("Hosts: 2"), ipad.label)
        XCTAssertFalse(ipad.label.contains("This Device"), ipad.label)
        let legacy = element("account.pushDevice.\(Self.legacyDevice)", in: app)
        XCTAssertTrue(reveal(legacy, in: app), "沒有舊版 app 的裝置列")
        XCTAssertTrue(legacy.label.contains("Unnamed Device"), legacy.label)

        app.buttons["account.pushDevice.\(Self.studioIPad).actions"].tap()
        app.buttons["Rename…"].firstMatch.tap()
        // SwiftUI 不把 identifier 帶到 alert 裡的 TextField。
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "沒有改名欄位")
        field.clearAndType("Desk iPad")
        app.alerts.buttons["account.pushDevices.save"].firstMatch.tap()

        expectLabel(of: ipad, contains: "Desk iPad")
    }

    /// 遠端關閉別支裝置：先確認，確認後從清單消失。
    @MainActor
    func testTurnsOffAnotherDevice() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        openAccount(app)

        let ipad = element("account.pushDevice.\(Self.studioIPad)", in: app)
        XCTAssertTrue(reveal(ipad, in: app), "沒有 Studio iPad 的列")
        app.buttons["account.pushDevice.\(Self.studioIPad).actions"].tap()
        app.buttons["Turn Off Notifications…"].firstMatch.tap()

        let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "沒有先確認")
        confirm.tap()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: ipad)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "關閉後仍在清單")
    }

    /// 訂閱到期(已登入、沒有 Purrdr Plus):仍列出裝置並可遠端關閉遺失的裝置，但不能改名。
    @MainActor
    func testWithoutPlusCanStillTurnOffDevices() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        openAccount(app)

        let ipad = element("account.pushDevice.\(Self.studioIPad)", in: app)
        XCTAssertTrue(reveal(ipad, in: app), "沒有 Plus 時沒有列出裝置")
        app.buttons["account.pushDevice.\(Self.studioIPad).actions"].tap()
        XCTAssertFalse(app.buttons["Rename…"].firstMatch.waitForExistence(timeout: 2), "沒有 Plus 仍能改名")
        app.buttons["Turn Off Notifications…"].firstMatch.tap()
        let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "沒有先確認")
        confirm.tap()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: ipad)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "關閉後仍在清單")
    }

    /// 這支裝置開了主機後列出並標「This Device」;從這裡關閉後，「通知」區塊的主機回到關閉。
    @MainActor
    func testTurningOffThisDeviceTurnsHostsOff() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        openAccount(app)

        let toggle = app.switches["account.push.\(Self.seededHost)"]
        XCTAssertTrue(reveal(toggle, in: app), "沒有主機的通知開關")
        toggle.tap()
        let install = app.alerts.buttons["settings.push.install"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        install.tap()
        expectValue("Notifications On", of: toggle)

        let thisDevice = element("account.pushDevice.\(Self.thisDevice)", in: app)
        XCTAssertTrue(reveal(thisDevice, in: app), "開了主機後沒有列出這支裝置")
        expectLabel(of: thisDevice, contains: "This Device")
        app.buttons["account.pushDevice.\(Self.thisDevice).actions"].tap()
        app.buttons["Turn Off Notifications…"].firstMatch.tap()
        let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        expectValue("Notifications Off", of: toggle)
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
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            list.swipeUp()
        }
        return target.exists && target.isHittable
    }

    @MainActor
    private func expectValue(_ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10)
        XCTAssertEqual(result, .completed, "\(element.identifier) 不是「\(value)」:\(String(describing: element.value))", file: file, line: line)
    }

    @MainActor
    private func expectLabel(of element: XCUIElement, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10)
        XCTAssertEqual(result, .completed, "\(element.identifier) 沒有「\(text)」:\(element.label)", file: file, line: line)
    }
}
