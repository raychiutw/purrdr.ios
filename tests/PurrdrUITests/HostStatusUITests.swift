import XCTest

/// 主機頁(ⓘ)下方的主機服務區塊(#290)。UI 測試替身：主機服務有新版 0.7.1,立即更新後重新連線就是新版。
final class HostStatusUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 主機清單 HTTPS 主機的 ⓘ:看到版本與最新版本;立即更新後顯示已更新;自動更新開關即時反映。
    @MainActor
    func testUpdateHostServiceAndToggleAutoUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedPairedHTTPSHost"])
        openStatus(app)

        let version = app.descendants(matching: .any)["hostStatus.hostService.version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "沒有主機服務版本")
        XCTAssertTrue(app.descendants(matching: .any)["hostStatus.hostService.latest"].firstMatch.label.contains("0.7.1"))

        let autoUpdate = app.switches["hostStatus.hostService.autoUpdate"]
        XCTAssertTrue(autoUpdate.exists)
        XCTAssertEqual(autoUpdate.value as? String, "1")
        autoUpdate.switches.firstMatch.tap()
        XCTAssertTrue(autoUpdate.waitForValue("0", timeout: 5), "自動更新沒有關掉")

        let update = app.buttons["hostStatus.hostService.update"]
        XCTAssertTrue(update.isEnabled)
        update.tap()
        let updated = app.descendants(matching: .any)["hostStatus.hostService.updateResult"].firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 20), "沒有更新結果")
        XCTAssertTrue(updated.label.contains("Updated to 0.7.1"), updated.label)
        XCTAssertTrue(version.label.contains("0.7.1"), "版本沒有換成新版")
    }

    /// 唯讀裝置(啟動時已用唯讀權杖配對):看得到狀態，立即更新與自動更新停用並說明。
    @MainActor
    func testReadOnlyDeviceCannotUpdate() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedReadOnlyHTTPSHost"])
        openStatus(app)

        let version = app.descendants(matching: .any)["hostStatus.hostService.version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "沒有主機服務版本")
        XCTAssertFalse(app.buttons["hostStatus.hostService.update"].isEnabled, "唯讀裝置不能立即更新")
        XCTAssertFalse(app.switches["hostStatus.hostService.autoUpdate"].isEnabled, "唯讀裝置不能改自動更新")
        XCTAssertTrue(app.descendants(matching: .any)["hostStatus.hostService.readOnly"].firstMatch.exists, "沒有說明唯讀")
    }

    @MainActor
    private func openStatus(_ app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["menu.hosts"].tap()
        // 主機狀態區塊在主機頁(列尾 ⓘ)最下方。
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "hosts.info.", "Studio")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "主機清單沒有 Studio")
        info.tap()
        XCTAssertTrue(app.buttons["hostEditor.save"].waitForExistence(timeout: 5), "沒有開啟主機頁")
        for _ in 0..<6 {
            app.swipeUp()
        }
    }
}

private extension XCUIElement {
    /// 等到 `value` 變成 `expected`。
    func waitForValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
