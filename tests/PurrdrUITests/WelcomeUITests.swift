import XCTest

/// 第一次開啟的歡迎頁(#34)。UI 測試預設當作看過;`-showWelcome` 模擬第一次開啟。
final class WelcomeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
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

}
