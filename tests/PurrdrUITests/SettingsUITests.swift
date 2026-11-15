import XCTest

/// 設定頁(#32):版本、主機 herdr 版本、評分、支援、診斷資訊、隱私權政策、Return 送出、觸覺回饋、會員入口;
/// 沒有 app 內深淺色設定;繁體中文介面。
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsShowsEntriesAndHostHerdrVersion() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)

        for identifier in ["settings.member", "settings.returnSends", "settings.haptics", "settings.rate", "settings.support"] {
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5), "設定頁沒有 \(identifier)")
        }
        let herdrVersion = element("settings.herdrVersion", in: app)
        scrollTo(herdrVersion, in: app)
        // Demo 主機回報 herdr 0.9.5。
        let version = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "0.9.5", "0.9.5")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "沒有顯示主機的 herdr 版本")
        XCTAssertTrue(element("settings.version", in: app).exists)
        XCTAssertTrue(element("settings.privacy", in: app).exists)
        // 外觀跟隨系統：沒有深淺色設定。
        for word in ["Appearance", "Dark", "Light"] {
            XCTAssertFalse(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch.exists,
                "設定頁不該有「\(word)」"
            )
        }
    }

    @MainActor
    func testCopyDiagnosticsConfirmsCopy() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)

        let copy = app.buttons["settings.copyDiagnostics"]
        scrollTo(copy, in: app)
        XCTAssertEqual(copy.label, "Copy Diagnostics")
        copy.tap()

        expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: copy)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testMemberIsPushedInsideSettingsSheet() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)

        app.buttons["settings.member"].tap()

        XCTAssertTrue(app.navigationBars["Purrdr Member"].waitForExistence(timeout: 5), "沒有進入會員畫面")
        // 同一個 sheet 內 push:有返回鈕，沒有第二個「完成」。
        app.navigationBars["Purrdr Member"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("sheet.settings", in: app).waitForExistence(timeout: 5), "沒有回到設定頁")
    }

    /// String Catalog 真的套用到 package 裡的畫面(畫面字串在 PurrdrFeatures,catalog 在 app)。
    @MainActor
    func testTraditionalChineseInterface() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])

        XCTAssertTrue(app.navigationBars["Agent"].waitForExistence(timeout: 10), "列表標題不是繁體中文")
        openSettings(in: app)
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5), "設定頁標題不是繁體中文")
        XCTAssertTrue(app.buttons["為 Purrdr 評分"].exists, "沒有「為 Purrdr 評分」")
        XCTAssertEqual(app.buttons["sheet.done"].label, "完成")
    }

    // MARK: - 輔助

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let more = app.buttons["toolbar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "列表工具列沒有「⋯」")
        more.tap()
        let item = app.buttons["menu.settings"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(element("sheet.settings", in: app).waitForExistence(timeout: 10), "沒有開出設定")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable, attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
    }
}
