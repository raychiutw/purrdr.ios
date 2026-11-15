import XCTest

/// 設定頁的推播開關(#29)。UI 測試只有 Demo 主機、不連網路，所以驗證：
/// 開關在設定頁、標示 Windows best-effort;Demo 主機打開時說明「先選自己的主機」,不跳系統權限對話框。
final class PushSettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.open(URL(string: "purrdr://settings")!)
        XCTAssertTrue(app.descendants(matching: .any)["sheet.settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPushToggleIsInSettingsAndMentionsWindowsBestEffort() {
        let app = XCUIApplication.launchUITesting()
        openSettings(app)

        let toggle = app.switches["settings.push"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "best-effort")).firstMatch.exists)
    }

    @MainActor
    func testTurningOnWithDemoHostExplainsWithoutPermissionPrompt() {
        let app = XCUIApplication.launchUITesting()
        openSettings(app)

        let toggle = app.switches["settings.push"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any)["settings.push.problem"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        // 沒有跳系統的通知權限對話框。
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
}
