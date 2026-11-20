import XCTest

/// 設定頁(#32、#246):外觀、Return 送出、觸覺回饋、評分、支援、診斷資訊、關於(版本、主機 herdr 版本、隱私權政策);
/// 會員與 Purrdr Plus 不在設定頁(在帳號頁);繁體中文介面。
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsShowsEntriesAndHostHerdrVersion() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)

        // 後面的列可能要捲動才出現(List 不建立畫面外的列)。
        for identifier in ["settings.appearance", "settings.returnSends", "settings.haptics", "settings.rate", "settings.support"] {
            let entry = element(identifier, in: app)
            scrollTo(entry, in: app)
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "設定頁沒有 \(identifier)")
        }
        let herdrVersion = element("settings.herdrVersion", in: app)
        // 捲到最後一列(隱私權政策):herdr 版本列可能只露出一部分，露出部分就算 hittable,值卻還沒進 accessibility 樹。
        scrollTo(element("settings.privacy", in: app), in: app)
        // Demo 主機回報 herdr 0.9.5。
        let version = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "0.9.5", "0.9.5")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "沒有顯示主機的 herdr 版本:\(herdrVersion.debugDescription)")
        XCTAssertTrue(element("settings.version", in: app).exists)
        XCTAssertTrue(element("settings.privacy", in: app).exists)
        // 會員與 Purrdr Plus 移到帳號頁(#246)。
        XCTAssertFalse(element("settings.member", in: app).exists, "設定頁不該有會員")
        XCTAssertFalse(element("settings.hostSync", in: app).exists, "設定頁不該有主機同步")
    }

    /// 外觀(#246):自動／淺色／深色，預設自動;選了立即生效，重開 app 後保留。
    @MainActor
    func testAppearanceChoicePersistsAcrossLaunches() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        // 外觀存在 UserDefaults.standard:結束時改回自動，不影響其他測試。
        addTeardownBlock { @MainActor in
            let cleanup = XCUIApplication.launchUITesting()
            self.openSettings(in: cleanup)
            cleanup.buttons["Automatic"].tap()
            cleanup.terminate()
        }

        XCTAssertTrue(app.buttons["Automatic"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Automatic"].isSelected, "預設不是自動")
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons["Dark"].isSelected)
        app.terminate()

        let relaunched = XCUIApplication.launchUITesting()
        openSettings(in: relaunched)
        XCTAssertTrue(relaunched.buttons["Dark"].waitForExistence(timeout: 5))
        XCTAssertTrue(relaunched.buttons["Dark"].isSelected, "重開 app 後沒有保留深色")
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

    /// String Catalog 真的套用到 package 裡的畫面(畫面字串在 PurrdrFeatures,catalog 在 app)。
    @MainActor
    func testTraditionalChineseInterface() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])

        // 列表沒有導覽列標題(#268):看 Agents／Spaces 分段控制。
        XCTAssertTrue(app.listModeControl.waitForExistence(timeout: 10), "沒有看到列表")
        XCTAssertEqual(app.textFields["agentList.search"].firstMatch.placeholderValue, "搜尋", "列表不是繁體中文")
        openSettings(in: app)
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5), "設定頁標題不是繁體中文")
        // Codex 區在上面，評分列要捲動才出現。
        let rate = app.buttons["為 Purrdr 評分"]
        scrollTo(rate, in: app)
        XCTAssertTrue(rate.waitForExistence(timeout: 5), "沒有「為 Purrdr 評分」")
        XCTAssertEqual(app.buttons["sheet.done"].label, "完成")
    }

    /// 設定頁只有外觀、鍵盤與觸覺、App 鎖(#284)、支援、關於(#274,原型 purrdr-settings C);主機設定不在這裡。
    @MainActor
    func testSettingsHasOnlyAppWideSections() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        XCTAssertFalse(app.switches["settings.hostTheme"].exists, "主機主題應在主機頁")
        XCTAssertFalse(app.switches["settings.codexLauncher"].exists, "Codex 啟動器應在主機頁")
        for header in ["Appearance", "Keyboard and Haptics", "App Lock", "Support", "About"] {
            let text = app.staticTexts[header].firstMatch
            scrollTo(text, in: app)
            XCTAssertTrue(text.exists, "設定頁沒有「\(header)」")
        }
    }

    /// 設定頁只有原型有的段落說明(外觀下的「自動」),其他段落沒有功能說明(#276)。
    @MainActor
    func testSettingsShowsOnlyPrototypeFooter() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        XCTAssertTrue(app.staticTexts["Automatic follows your device’s Light or Dark setting."].firstMatch.waitForExistence(timeout: 5))
        let privacy = element("settings.privacy", in: app)
        scrollTo(privacy, in: app)
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diagnostics include")).firstMatch
        XCTAssertFalse(paragraph.exists, "支援段不該有功能說明段落")
    }

    /// Codex 啟動器(#24,ADR-0002)在主機頁(#274):打開先問同意(說明會加什麼、以哪個使用者),確認才安裝;關閉就移除。
    /// 已存主機的通道是 Demo 主機，家目錄在記憶體。
    @MainActor
    func testCodexLauncherAsksConsentThenInstallsAndRemoves() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        app.openSeededHostPage()

        let toggle = app.switches["settings.codexLauncher"]
        scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "主機頁沒有 Codex 啟動器")
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("~/.local/bin/codex"), "沒說明會加什麼:\(message)")
        XCTAssertTrue(message.contains("demo"), "沒說明以哪個使用者:\(message)")
        alert.buttons["Install"].tap()

        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)

        toggle.switches.firstMatch.tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.alerts.firstMatch.exists, "移除不該再問同意")
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
