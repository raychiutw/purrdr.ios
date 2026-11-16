import XCTest

/// 第一次開啟的歡迎頁(#34)。UI 測試預設當作看過;`-showWelcome` 模擬第一次開啟。
final class WelcomeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchShowsWelcomeAndTryDemoReturnsToList() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])

        let sheet = app.descendants(matching: .any)["sheet.welcome"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["What You Need"].exists || app.otherElements["What You Need"].exists)
        XCTAssertTrue(app.buttons["welcome.rate"].exists)
        XCTAssertTrue(app.buttons["welcome.addHost"].exists)

        app.buttons["welcome.demo"].tap()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["agent.row.demo/w2:p1"].firstMatch))
    }

    @MainActor
    func testWithoutFirstLaunchFlagNoWelcome() {
        let app = XCUIApplication.launchUITesting()

        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["agent.row.demo/w2:p1"].firstMatch))
        XCTAssertFalse(app.descendants(matching: .any)["sheet.welcome"].exists)
    }

    @MainActor
    func testAddHostOpensHosts() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])
        XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitForExistence(timeout: 10))

        app.buttons["welcome.addHost"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["sheet.hosts"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsReopensWelcome() {
        let app = XCUIApplication.launchUITesting()
        app.open(URL(string: "purrdr://settings")!)
        XCTAssertTrue(app.descendants(matching: .any)["sheet.settings"].waitForExistence(timeout: 10))

        let row = app.buttons["settings.welcome"]
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
        }
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitForExistence(timeout: 5))
    }
}
