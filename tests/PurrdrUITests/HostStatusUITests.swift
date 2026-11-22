import XCTest

/// 主機 tab 的主機服務區塊(#290、#392)。UI 測試替身：主機服務有新版 1.0.1,立即更新後重新連線就是新版。
final class HostStatusUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// HTTPS 主機的主機 tab:看到版本與最新版本;立即更新後顯示已更新;自動更新開關即時反映。
    @MainActor
    func testUpdateHostServiceAndToggleAutoUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedPairedHTTPSHost"])
        openStatus(app)

        let version = app.descendants(matching: .any)["hostStatus.hostService.version"].firstMatch
        XCTAssertTrue(version.waitUntilExists(timeout: 10), "沒有主機服務版本")
        XCTAssertTrue(app.descendants(matching: .any)["hostStatus.hostService.latest"].firstMatch.label.contains("1.0.1"))

        let autoUpdate = app.switches["hostStatus.hostService.autoUpdate"]
        XCTAssertTrue(autoUpdate.exists)
        XCTAssertEqual(autoUpdate.value as? String, "1")
        autoUpdate.switches.firstMatch.tap()
        XCTAssertTrue(autoUpdate.waitForValue("0", timeout: 5), "自動更新沒有關掉")

        let update = app.buttons["hostStatus.hostService.update"]
        XCTAssertTrue(update.isEnabled)
        update.tap()
        let updated = app.descendants(matching: .any)["hostStatus.hostService.updateResult"].firstMatch
        XCTAssertTrue(updated.waitUntilExists(timeout: 20), "沒有更新結果")
        XCTAssertTrue(updated.label.contains("Updated to 1.0.1"), updated.label)
        XCTAssertTrue(version.label.contains("1.0.1"), "版本沒有換成新版")
    }

    /// 唯讀裝置(啟動時已用唯讀權杖配對):看得到狀態，立即更新與自動更新停用並說明。
    @MainActor
    func testReadOnlyDeviceCannotUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedReadOnlyHTTPSHost"])
        openStatus(app)

        let version = app.descendants(matching: .any)["hostStatus.hostService.version"].firstMatch
        XCTAssertTrue(version.waitUntilExists(timeout: 10), "沒有主機服務版本")
        XCTAssertFalse(app.buttons["hostStatus.hostService.update"].isEnabled, "唯讀裝置不能立即更新")
        XCTAssertFalse(app.switches["hostStatus.hostService.autoUpdate"].isEnabled, "唯讀裝置不能改自動更新")
        XCTAssertTrue(app.descendants(matching: .any)["hostStatus.hostService.readOnly"].firstMatch.exists, "沒有說明唯讀")
    }

    @MainActor
    private func openStatus(_ app: XCUIApplication) {
        app.openHostsTab()
        // 主機服務區塊在主機 tab 總頁(#392)。
        let last = app.descendants(matching: .any)["hostStatus.hostService.autoUpdate"].firstMatch
        XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 10), "沒有開啟主機 tab")
        for _ in 0..<8 where !last.exists || !last.isHittable {
            app.swipeUp()
        }
    }
}
