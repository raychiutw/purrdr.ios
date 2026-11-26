import XCTest

/// App 鎖(#284)。驗證用 app 的替身：第一次解鎖驗證回「取消」(像關掉啟動時的 Face ID),之後成功;
/// `-uiTestingAppLock` 以已開啟啟動，`-uiTestingNoPasscode` 模擬沒有裝置密碼。
final class AppLockUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testColdStartShowsLockScreenUntilUnlocked() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingAppLock"])

        let title = app.staticTexts["appLock.title"]
        XCTAssertTrue(title.waitUntilExists(timeout: 10), "冷啟動沒有鎖定畫面")
        XCTAssertEqual(title.label, "Purrdr Is Locked")
        let unlock = app.buttons["appLock.unlock"]
        XCTAssertEqual(unlock.label, "Unlock")
        XCTAssertFalse(app.chatListReady.isHittable, "鎖定畫面沒有遮住列表")

        unlock.tap()

        XCTAssertTrue(title.waitUntilGone(timeout: 10), "解鎖後鎖定畫面沒有消失")
        XCTAssertTrue(app.chatListReady.waitUntilExists(timeout: 10))
        XCTAssertTrue(app.chatListReady.isHittable, "解鎖後列表不能操作")
    }

    /// 預設關閉;開啟時先驗證，在前景開啟不會馬上鎖住。
    @MainActor
    func testTurnOnFromSettings() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)

        let toggle = app.switches["settings.appLock"]
        app.scrollIntoView(toggle, search: .down)
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "設定頁沒有 App 鎖")
        XCTAssertEqual(toggle.label, "Require Face ID")
        XCTAssertEqual(toggle.value as? String, "0", "App 鎖預設應關閉")
        XCTAssertFalse(app.descendants(matching: .any)["settings.appLock.footer"].exists, "能用時不放功能說明(#276)")

        toggle.switches.firstMatch.tap()

        XCTAssertTrue(toggle.wait(for: NSPredicate(format: "value == '1'"), timeout: 5), "等待的條件沒有成立")
        XCTAssertFalse(app.staticTexts["appLock.title"].exists, "在前景開啟不該馬上鎖住")
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        app.openSettingsSheet()
    }

}
