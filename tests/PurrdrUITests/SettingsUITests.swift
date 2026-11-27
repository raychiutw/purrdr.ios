import UIKit
import XCTest

/// 設定頁(#32、#246):外觀、Return 送出、觸覺回饋、評分、支援、診斷資訊、關於(版本、隱私權政策);
/// 會員與 Purrdr Plus 不在設定頁(在帳號頁);繁體中文介面。
final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 「Copy Diagnostics」會寫入全域剪貼簿,測完清掉,不影響之後的測試。
    override func tearDown() {
        UIPasteboard.general.items = []
    }

    /// 設定頁的內容(#32、#246、#274、#276):只有 App 層級的段落(外觀、鍵盤與觸覺、送出可撤回、App 鎖、支援、關於);
    /// 外觀下的「自動」與送出可撤回的秒數說明、支援段的隱私揭露是例外，數據用量列下沒有說明;主機設定與會員不在這裡。
    /// 一次啟動由上而下檢查(#372:原本四個測試各啟動一次);啟動本身就是深層連結 `purrdr://settings` 的冷啟動
    /// (沒有先啟動再開連結:冷啟動要直接開出帳號與設定 sheet),之後才逐段檢查。
    @MainActor
    func testSettingsDeepLinkFromColdLaunchThenSectionsCopyDiagnosticsAppearanceAndAppLock() {
        let app = XCUIApplication.uiTesting()
        app.terminate()
        app.open(URL(string: "purrdr://settings")!)
        app.waitForAccountSheet(timeout: 15)
        XCTAssertFalse(app.switches["settings.hostTheme"].exists, "主機主題應在主機頁")
        XCTAssertFalse(app.switches["settings.codexLauncher"].exists, "Codex 啟動器應在主機頁")
        XCTAssertTrue(app.staticTexts["Automatic follows your device’s Light or Dark setting."].firstMatch.waitUntilExists(timeout: 5))
        func expectHeaders(_ headers: [String]) {
            for header in headers {
                let text = app.staticTexts[header].firstMatch
                app.scrollIntoView(text, search: .down)
                XCTAssertTrue(text.exists, "設定頁沒有「\(header)」")
            }
        }
        // 由上而下的順序捲:外觀、鍵盤與觸覺 → 送出可撤回(0–10 秒的 Stepper,說明在註腳)→ 各列 → App 鎖、支援、關於。
        expectHeaders(["Appearance", "Keyboard and Haptics"])
        let undoSend = app.steppers["settings.undoSend"].firstMatch
        app.scrollIntoView(undoSend, search: .down)
        XCTAssertTrue(undoSend.exists, "設定頁沒有送出可撤回")
        XCTAssertTrue(app.staticTexts["After you send, the message waits this long so you can undo it."].firstMatch.exists)
        for identifier in ["settings.returnSends", "settings.haptics", "settings.rate", "settings.support"] {
            let entry = app.element(identifier)
            app.scrollIntoView(entry, search: .down)
            XCTAssertTrue(entry.waitUntilExists(timeout: 5), "設定頁沒有 \(identifier)")
        }
        XCTAssertFalse(app.element("settings.dataUsage").exists, "數據用量已移到流量 tab")
        expectHeaders(["App Lock", "Support", "About"])
        let privacy = app.element("settings.privacy")
        app.scrollIntoView(privacy, search: .down)
        let paragraph = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Diagnostics include")).firstMatch
        XCTAssertTrue(paragraph.exists, "支援段要保留診斷資訊的隱私揭露")
        // herdr 版本只在主機 tab 逐台顯示(#419),設定頁不再有。
        XCTAssertFalse(app.element("settings.herdrVersion").exists, "設定頁不該顯示 herdr 版本")
        XCTAssertFalse(app.staticTexts["herdr on Host"].exists)
        XCTAssertTrue(app.element("settings.version").exists)
        XCTAssertTrue(privacy.exists)
        // 會員與 Purrdr Plus 移到帳號頁(#246)。
        XCTAssertFalse(app.element("settings.member").exists, "設定頁不該有會員")
        XCTAssertFalse(app.element("settings.hostSync").exists, "設定頁不該有主機同步")

        // 複製診斷資訊:按下後鈕的文字變「Copied」。
        let copy = app.buttons["settings.copyDiagnostics"]
        app.scrollIntoView(copy, search: .down)
        XCTAssertEqual(copy.label, "Copy Diagnostics")
        copy.tap()

        XCTAssertTrue(copy.wait(for: NSPredicate(format: "label == %@", "Copied"), timeout: 5), "等待的條件沒有成立")

        // 外觀即時生效(#322):設定 sheet 開著時切換，sheet 本身立刻變深或變淺;切回自動回到系統的深淺色。
        // 以 sheet 截圖的平均亮度判斷(accessibility 樹看不到深淺色)。`-uiTesting` 每次啟動都清掉偏好,最後切回自動只是為了驗證它。
        let sheet = app.element("account.signedOut")
        app.scrollIntoView(app.buttons["Automatic"], search: .up)
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

        // App 鎖(#284):預設關閉;開啟時先驗證，在前景開啟不會馬上鎖住(放最後)。
        let lock = app.switches["settings.appLock"]
        app.scrollIntoView(lock, search: .down)
        XCTAssertTrue(lock.waitUntilExists(timeout: 5), "設定頁沒有 App 鎖")
        XCTAssertEqual(lock.label, "Require Face ID")
        XCTAssertEqual(lock.value as? String, "0", "App 鎖預設應關閉")
        XCTAssertFalse(app.descendants(matching: .any)["settings.appLock.footer"].exists, "能用時不放功能說明(#276)")
        lock.switches.firstMatch.tap()
        XCTAssertTrue(lock.wait(for: NSPredicate(format: "value == '1'"), timeout: 5), "App 鎖沒有開啟")
        XCTAssertFalse(app.staticTexts["appLock.title"].exists, "在前景開啟不該馬上鎖住")
    }

    /// String Catalog 真的套用到 package 裡的畫面(畫面字串在 PurrdrFeatures,catalog 在 app)。
    @MainActor
    func testTraditionalChineseInterface() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])

        // 聊天頂列:新增聊天鈕在(搜尋欄 placeholder 的繁中由 StringCatalogTests 與 `scripts/strings.sh check` 守,不必往下拉出搜尋欄)。
        XCTAssertTrue(app.chatListReady.waitUntilExists(timeout: 10), "沒有看到列表")
        openSettings(in: app)
        XCTAssertTrue(app.navigationBars["帳號"].waitUntilExists(timeout: 5), "帳號與設定頁標題不是繁體中文")
        XCTAssertTrue(app.staticTexts["用量顯示"].waitUntilExists(timeout: 5), "設定沒有「用量顯示」")
        // Codex 區在上面，評分列要捲動才出現。
        let rate = app.buttons["為 Purrdr 評分"]
        app.scrollIntoView(rate, search: .down)
        XCTAssertTrue(rate.waitUntilExists(timeout: 5), "沒有「為 Purrdr 評分」")
        XCTAssertFalse(app.buttons["sheet.close"].exists, "設定是 tab,沒有關閉鈕")
    }

    // MARK: - 輔助

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        app.openSettingsSheet()
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
