import XCTest

/// App 鎖(#284)。驗證用 app 的替身：第一次解鎖驗證回「取消」(像關掉啟動時的 Face ID),之後成功;
/// `-uiTestingAppLock` 以已開啟啟動，`-uiTestingNoPasscode` 模擬沒有裝置密碼。
final class AppLockUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testColdStartShowsLockScreenUntilUnlocked() {
        let app = XCUIApplication.launchUITesting(flags: [.uiTestingAppLock])

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

    // 從設定開啟 App 鎖的檢查在 SettingsUITests.testSettingsSectionsCopyDiagnosticsAppearanceAndAppLock。
}
