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
        XCTAssertTrue(sheet.waitUntilExists(timeout: 10))
        XCTAssertTrue(app.staticTexts["What You Need"].exists || app.otherElements["What You Need"].exists)
        XCTAssertTrue(app.buttons["welcome.rate"].exists)
        XCTAssertTrue(app.buttons["welcome.addHost"].exists)

        app.buttons["welcome.demo"].tap()

        XCTAssertTrue(sheet.waitUntilGone(timeout: 5))
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["spaces.tab.demo/w2:t1"].firstMatch))
    }

    /// 準備事項的主機包含 Windows(#26 已支援),英文與繁中都是(#35)。
    @MainActor
    func testHostRequirementIncludesWindows() {
        for flags in [[], ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]] {
            let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"] + flags)
            XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitUntilExists(timeout: 10))
            let host = app.descendants(matching: .any)["welcome.requirement.host"].firstMatch
            XCTAssertTrue(host.waitUntilExists(timeout: 5), "沒有主機的準備事項")
            XCTAssertTrue(host.label.contains("Windows"), "沒提到 Windows:\(host.label)")
            XCTAssertTrue(host.label.contains("Linux"), host.label)
            app.terminate()
        }
    }

    @MainActor
    func testWithoutFirstLaunchFlagNoWelcome() {
        let app = XCUIApplication.launchUITesting()

        XCTAssertTrue(app.reveal(app.descendants(matching: .any)["spaces.tab.demo/w2:t1"].firstMatch))
        XCTAssertFalse(app.descendants(matching: .any)["sheet.welcome"].exists)
    }

    @MainActor
    func testAddHostOpensHosts() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])
        XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitUntilExists(timeout: 10))

        app.buttons["welcome.addHost"].tap()

        // 直接進新增主機引導(#332:歡迎頁、空列表、主機清單的新增都走引導)。
        XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有直接開出新增主機引導")
    }

    @MainActor
    func testSettingsReopensWelcome() {
        let app = XCUIApplication.launchUITesting()
        app.open(URL(string: "purrdr://settings")!)
        app.waitForAccountSheet()

        let row = app.buttons["settings.welcome"]
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
        }
        row.tap()

        XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitUntilExists(timeout: 5))
    }
}
