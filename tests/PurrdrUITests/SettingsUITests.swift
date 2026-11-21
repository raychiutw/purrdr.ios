import UIKit
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
            let entry = app.element(identifier)
            app.scrollIntoView(entry, search: .down)
            XCTAssertTrue(entry.waitUntilExists(timeout: 5), "設定頁沒有 \(identifier)")
        }
        let herdrVersion = app.element("settings.herdrVersion")
        // 捲到最後一列(隱私權政策):herdr 版本列可能只露出一部分，露出部分就算 hittable,值卻還沒進 accessibility 樹。
        app.scrollIntoView(app.element("settings.privacy"), search: .down)
        // Demo 主機回報 herdr 0.9.5。
        let version = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "0.9.5", "0.9.5")).firstMatch
        XCTAssertTrue(version.waitUntilExists(timeout: 10), "沒有顯示主機的 herdr 版本:\(herdrVersion.debugDescription)")
        XCTAssertTrue(app.element("settings.version").exists)
        XCTAssertTrue(app.element("settings.privacy").exists)
        // 會員與 Purrdr Plus 移到帳號頁(#246)。
        XCTAssertFalse(app.element("settings.member").exists, "設定頁不該有會員")
        XCTAssertFalse(app.element("settings.hostSync").exists, "設定頁不該有主機同步")
    }

    /// 各頁不放功能說明段落(#276):數據用量那一列下方沒有說明。
    @MainActor
    func testDataUsageRowHasNoExplanation() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        let entry = app.element("settings.dataUsage")
        app.scrollIntoView(entry, search: .down)
        XCTAssertFalse(app.staticTexts["How much data Purrdr uses to talk to your hosts."].exists, "數據用量列下方不該有說明")
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

        XCTAssertTrue(app.buttons["Automatic"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["Automatic"].isSelected, "預設不是自動")
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons["Dark"].isSelected)
        app.terminate()

        let relaunched = XCUIApplication.launchUITesting()
        openSettings(in: relaunched)
        XCTAssertTrue(relaunched.buttons["Dark"].waitUntilExists(timeout: 5))
        XCTAssertTrue(relaunched.buttons["Dark"].isSelected, "重開 app 後沒有保留深色")
    }

    /// 外觀即時生效(#322):設定 sheet 開著時切換，sheet 本身立刻變深或變淺;切回自動回到系統的深淺色。
    /// 以 sheet 截圖的平均亮度判斷(accessibility 樹看不到深淺色)。
    @MainActor
    func testAppearanceChoiceRecolorsOpenSettingsSheet() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        addTeardownBlock { @MainActor in
            let cleanup = XCUIApplication.launchUITesting()
            self.openSettings(in: cleanup)
            cleanup.buttons["Automatic"].tap()
            cleanup.terminate()
        }
        let sheet = app.element("sheet.settings")
        XCTAssertTrue(app.buttons["Automatic"].waitUntilExists(timeout: 5))
        let system = luminance(of: sheet)

        app.buttons["Dark"].tap()
        XCTAssertTrue(waitForLuminance(of: sheet) { $0 < 0.3 }, "選深色後設定 sheet 不是深色(亮度 \(luminance(of: sheet)))")
        app.buttons["Light"].tap()
        XCTAssertTrue(waitForLuminance(of: sheet) { $0 > 0.7 }, "選淺色後設定 sheet 不是淺色(亮度 \(luminance(of: sheet)))")
        app.buttons["Dark"].tap()
        XCTAssertTrue(waitForLuminance(of: sheet) { $0 < 0.3 }, "再選深色後設定 sheet 不是深色(亮度 \(luminance(of: sheet)))")
        app.buttons["Automatic"].tap()
        XCTAssertTrue(
            waitForLuminance(of: sheet) { abs($0 - system) < 0.1 },
            "切回自動後設定 sheet 沒有回到系統的深淺色(亮度 \(luminance(of: sheet)),系統 \(system))")
    }

    /// 刪除會員(#322):按鈕寫「Delete Member」不帶刪節號，按下仍先跳確認。
    @MainActor
    func testDeleteMemberButtonHasNoEllipsisAndConfirms() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMember"])
        let account = app.buttons["toolbar.account"]
        XCTAssertTrue(account.waitUntilExists(timeout: 10))
        account.tap()
        let delete = app.buttons["member.delete"]
        app.scrollIntoView(delete, search: .down)
        XCTAssertTrue(delete.waitUntilExists(timeout: 10), "帳號頁沒有刪除會員")
        XCTAssertEqual(delete.label, "Delete Member")
        delete.tap()
        let confirm = app.sheets.buttons["Delete Member"].firstMatch
        let confirmInPlace = app.buttons["Delete Member"].firstMatch
        XCTAssertTrue(
            UITestWait.until(timeout: 5) { confirm.exists || confirmInPlace.exists },
            "按下刪除會員沒有先跳確認")
        XCTAssertTrue(app.staticTexts["Delete your member account?"].exists, "沒有確認的標題")
    }

    @MainActor
    func testCopyDiagnosticsConfirmsCopy() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)

        let copy = app.buttons["settings.copyDiagnostics"]
        app.scrollIntoView(copy, search: .down)
        XCTAssertEqual(copy.label, "Copy Diagnostics")
        copy.tap()

        expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: copy)
        waitForExpectations(timeout: 5)
    }

    /// String Catalog 真的套用到 package 裡的畫面(畫面字串在 PurrdrFeatures,catalog 在 app)。
    @MainActor
    func testTraditionalChineseInterface() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])

        // 列表沒有導覽列標題(#268):看 Agents／Spaces 切換。
        XCTAssertTrue(app.listModeControl.waitUntilExists(timeout: 10), "沒有看到列表")
        XCTAssertEqual(app.textFields["agentList.search"].firstMatch.placeholderValue, "搜尋", "列表不是繁體中文")
        openSettings(in: app)
        XCTAssertTrue(app.navigationBars["設定"].waitUntilExists(timeout: 5), "設定頁標題不是繁體中文")
        // Codex 區在上面，評分列要捲動才出現。
        let rate = app.buttons["為 Purrdr 評分"]
        app.scrollIntoView(rate, search: .down)
        XCTAssertTrue(rate.waitUntilExists(timeout: 5), "沒有「為 Purrdr 評分」")
        XCTAssertEqual(app.buttons["sheet.done"].label, "完成")
    }

    /// 設定頁只有外觀、鍵盤與觸覺、送出可撤回(#300)、App 鎖(#284)、支援、關於(#274,原型 purrdr-settings C);主機設定不在這裡。
    @MainActor
    func testSettingsHasOnlyAppWideSections() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        XCTAssertFalse(app.switches["settings.hostTheme"].exists, "主機主題應在主機頁")
        XCTAssertFalse(app.switches["settings.codexLauncher"].exists, "Codex 啟動器應在主機頁")
        func expectHeaders(_ headers: [String]) {
            for header in headers {
                let text = app.staticTexts[header].firstMatch
                app.scrollIntoView(text, search: .down)
                XCTAssertTrue(text.exists, "設定頁沒有「\(header)」")
            }
        }
        // 由上而下的順序捲:外觀、鍵盤與觸覺 → 送出可撤回(#300,0–10 秒的 Stepper,說明在註腳)→ App 鎖、支援、關於。
        expectHeaders(["Appearance", "Keyboard and Haptics"])
        let undoSend = app.steppers["settings.undoSend"].firstMatch
        app.scrollIntoView(undoSend, search: .down)
        XCTAssertTrue(undoSend.exists, "設定頁沒有送出可撤回")
        XCTAssertTrue(app.staticTexts["After you send, the message waits this long so you can undo it."].firstMatch.exists)
        expectHeaders(["App Lock", "Support", "About"])
    }

    /// 設定頁只有原型有的段落說明(外觀下的「自動」、送出可撤回的秒數說明)與支援段的隱私揭露(#276 的例外)。
    @MainActor
    func testSettingsShowsPrototypeFooterAndPrivacyDisclosure() {
        let app = XCUIApplication.launchUITesting()
        openSettings(in: app)
        XCTAssertTrue(app.staticTexts["Automatic follows your device’s Light or Dark setting."].firstMatch.waitUntilExists(timeout: 5))
        let privacy = app.element("settings.privacy")
        app.scrollIntoView(privacy, search: .down)
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diagnostics include")).firstMatch
        XCTAssertTrue(paragraph.exists, "支援段要保留診斷資訊的隱私揭露")
    }

    /// Codex 啟動器(#24,ADR-0002)在主機頁(#274):打開先問同意(說明會加什麼、以哪個使用者),確認才安裝;關閉就移除。
    /// 已存主機的通道是 Demo 主機，家目錄在記憶體。
    @MainActor
    func testCodexLauncherAsksConsentThenInstallsAndRemoves() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        app.openSeededHostPage()

        let toggle = app.switches["settings.codexLauncher"]
        app.scrollIntoView(toggle, search: .down)
        XCTAssertTrue(toggle.waitUntilExists(timeout: 5), "主機頁沒有 Codex 啟動器")
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 5), "沒有詢問同意")
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("Codex launcher"), "沒說明會加什麼:\(message)")
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
        XCTAssertTrue(more.waitUntilExists(timeout: 10), "列表工具列沒有「⋯」")
        more.tap()
        let item = app.buttons["menu.settings"]
        XCTAssertTrue(item.waitUntilExists(timeout: 5))
        item.tap()
        XCTAssertTrue(app.element("sheet.settings").waitUntilExists(timeout: 10), "沒有開出設定")
    }

    /// 元素截圖的平均亮度(0 黑～1 白)。
    @MainActor
    private func luminance(of element: XCUIElement) -> Double {
        guard let image = element.screenshot().image.cgImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return -1 }
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    /// 深淺色切換有動畫：等亮度符合條件(最多約 3 秒)。
    @MainActor
    private func waitForLuminance(of element: XCUIElement, _ condition: (Double) -> Bool) -> Bool {
        for _ in 0..<10 {
            if condition(luminance(of: element)) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

}
