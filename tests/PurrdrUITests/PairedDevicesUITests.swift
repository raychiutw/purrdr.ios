import XCTest

/// 主機頁(ⓘ)下方的已配對裝置(#291)。UI 測試替身：這支 iPhone 與另一支唯讀的 iPad。
final class PairedDevicesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 滑動別支裝置「撤銷」→ 確認後從列表消失;這支裝置沒有撤銷動作。
    @MainActor
    func testRevokeOtherDeviceAfterConfirmation() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedPairedHTTPSHost"])
        openStatus(app)

        let otherDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing-ipad"].firstMatch
        XCTAssertTrue(app.scrollIntoView(otherDevice, timeout: 10), "沒有另一支裝置")
        let thisDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing"].firstMatch
        XCTAssertTrue(thisDevice.label.contains("This Device"), thisDevice.label)

        thisDevice.swipeLeft()
        XCTAssertFalse(app.buttons["Revoke"].waitUntilExists(timeout: 2), "這支裝置不該能在列表撤銷")

        otherDevice.swipeLeft()
        let revoke = app.buttons["Revoke"]
        XCTAssertTrue(revoke.waitUntilExists(timeout: 5), "沒有撤銷鈕")
        revoke.tap()
        let confirm = app.buttons["pairedDevices.confirmRevoke"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有確認對話框")
        XCTAssertTrue(otherDevice.exists, "確認前就撤銷了")
        confirm.tap()

        XCTAssertTrue(otherDevice.waitUntilGone(timeout: 10), "撤銷後還在列表")
    }

    /// 「這支裝置」滑動是「移除主機」:在那一列上跳出移除主機的確認,確認後回到主機 tab 並移除(撤銷自己沿用移除主機流程)。
    @MainActor
    func testThisDeviceRowOpensHostRemoval() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedPairedHTTPSHost"])
        openStatus(app)

        let thisDevice = app.descendants(matching: .any)["pairedDevices.row.ui-testing"].firstMatch
        XCTAssertTrue(app.scrollIntoView(thisDevice, timeout: 10), "沒有這支裝置")
        thisDevice.swipeLeft()
        let remove = app.buttons["pairedDevices.removeHost"]
        XCTAssertTrue(remove.waitUntilExists(timeout: 5), "這支裝置沒有移除主機")
        remove.tap()

        let confirm = app.buttons["hosts.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有移除主機的確認")
        // 系統的確認對話框錨定在那一列,沒有 Cancel 鈕:點外面取消,不移除、留在這一頁。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { !confirm.exists }, "取消後確認沒有收起")
        XCTAssertTrue(thisDevice.exists, "取消後離開了已配對裝置頁")
    }

    @MainActor
    private func openStatus(_ app: XCUIApplication) {
        app.openHostsTab()
        // 已配對裝置在主機 tab 總頁的主機服務區塊下,點進去是「已配對裝置」子頁(#392)。
        let link = app.buttons["hosts.pairedDevices"].firstMatch
        XCTAssertTrue(app.scrollIntoView(link, timeout: 10), "主機 tab 沒有已配對裝置")
        link.tap()
        XCTAssertTrue(app.element("hosts.pairedDevices.page").waitUntilExists(timeout: 5), "沒有開啟已配對裝置")
    }

}
