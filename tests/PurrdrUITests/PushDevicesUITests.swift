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

    /// 左滑關閉(#626):與列上的選單同一個動作、先確認(確認前列還在);關掉所有裝置後顯示系統空狀態。
    @MainActor
    func testSwipeTurnsOffDevicesThenShowsEmptyState() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        app.openAccountSheet()

        openPushDevices(app)
        for id in [Self.studioIPad, Self.legacyDevice] {
            let row = app.element("account.pushDevice.\(id)")
            XCTAssertTrue(row.waitUntilExists(timeout: 10), "沒有 \(id) 的列")
            XCTAssertFalse(app.element("account.pushDevices.empty").exists, "還有裝置時不該顯示空狀態")
            app.buttons["account.pushDevice.\(id)"].swipeLeft()
            let swipeTurnOff = app.buttons["account.pushDevices.swipeTurnOff"].firstMatch
            XCTAssertTrue(swipeTurnOff.waitUntilExists(timeout: 5), "左滑沒有「關閉通知」")
            XCTAssertTrue(app.buttons["account.pushDevices.swipeRename"].firstMatch.exists, "有 Plus 時左滑也要有「改名」")
            swipeTurnOff.tap()
            let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
            XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "左滑沒有先確認")
            XCTAssertTrue(row.exists, "確認前列不該先被移走")
            confirm.tap()
            XCTAssertTrue(row.waitUntilGone(timeout: 10), "關閉後仍在清單")
        }
        XCTAssertTrue(app.element("account.pushDevices.empty").waitUntilExists(timeout: 10), "沒有裝置時沒有系統空狀態")
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
