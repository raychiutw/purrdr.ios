import XCTest

/// Pane 終端機:Demo 主機的 Pane(回顯 shell,控制字元以 `^C`、`^[` 顯示)。
final class PaneTerminalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 從 Agent 對話標題列的終端機鈕，打開該 Agent 自己的 Pane(#37 故事 43)。
    @MainActor
    private func openTerminal(_ app: XCUIApplication) -> XCUIElement {
        app.openConversation(paneID: "w1:p1")
        app.conversationMoreItem("terminal.open").tap()
        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        XCTAssertTrue(screen.waitUntilExists(timeout: 10), "沒有打開終端機")
        return screen
    }

    @MainActor
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    /// 同一次啟動串起終端機的基本行為:連線與狀態、往回捲、鍵盤接管、按鍵列、Ctrl 鎖定(#374 瘦身;原本各自啟動)。
    /// 順序刻意排好:先捲動(還沒打字)，再打字，之後的步驟接著前面輸入的內容往下斷言。
    @MainActor
    func testTerminalBehaviors() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)

        step("連線後標題列下方顯示狀態") {
            screen.expectValue(containing: "demo@purrdr ledger %")
            let status = app.descendants(matching: .any)["terminal.status"].firstMatch
            XCTAssertTrue(status.label.contains("Tidy up the CSV export"), "標題不對:\(status.label)")
            XCTAssertTrue(status.label.contains("Connected"), "狀態不對:\(status.label)")
        }

        // Demo 的 Pane 依 terminal.scroll 捲主機端 scrollback;打字後回到最新(#88 故事 17、19)。
        step("手指往下滑回看先前的輸出，打字後回到最新") {
            screen.expectValue(containing: "Wrote export/ledger-2026-11.csv")
            XCTAssertFalse((screen.value as? String)?.contains("python export.py") == true, "一開始就看得到最上面，測不出捲動")
            for _ in 0..<8 where (screen.value as? String)?.contains("python export.py") != true {
                screen.swipeDown()
            }
            screen.expectValue(containing: "python export.py")
            app.typeEnglish("l")
            screen.expectValue(containing: "demo@purrdr ledger % l")
        }

        step("按鍵列每顆都有標籤且至少 44pt") {
            let expected = [
                "esc": "Escape", "tab": "Tab", "ctrl": "Control", "alt": "Alt",
                "left": "Left Arrow", "down": "Down Arrow", "up": "Up Arrow", "right": "Right Arrow",
                "slash": "Slash", "hyphen": "Hyphen", "pipe": "Vertical Bar", "tilde": "Tilde",
                "home": "Home", "end": "End",
            ]
            for (id, label) in expected {
                let key = app.buttons["terminal.key.\(id)"].firstMatch
                XCTAssertTrue(key.exists, "沒有 \(id) 鍵")
                XCTAssertEqual(key.label, label)
                // 捲動容器裡的座標會有 1e-13 等級的浮點誤差。
                XCTAssertGreaterThanOrEqual(key.frame.width.rounded(), 44, "\(id) 鍵太窄")
                XCTAssertGreaterThanOrEqual(key.frame.height.rounded(), 44, "\(id) 鍵太矮")
            }
            // 貼上與收起鍵盤是列尾兩顆獨立的鈕。
            XCTAssertEqual(app.buttons["terminal.key.paste"].firstMatch.label, "Paste")
            XCTAssertEqual(app.buttons["terminal.key.keyboard"].firstMatch.label, "Hide Keyboard")
            for id in ["paste", "keyboard"] {
                let key = app.buttons["terminal.key.\(id)"].firstMatch
                XCTAssertTrue(key.exists, "沒有 \(id) 鈕")
                XCTAssertGreaterThanOrEqual(key.frame.width.rounded(), 44, "\(id) 鈕太窄")
                XCTAssertGreaterThanOrEqual(key.frame.height.rounded(), 44, "\(id) 鈕太矮")
            }
            // 最窄的寬度下 Esc、Tab、Ctrl、Alt 不用捲就看得到。
            for id in ["esc", "tab", "ctrl", "alt"] {
                XCTAssertTrue(app.buttons["terminal.key.\(id)"].firstMatch.isHittable, "\(id) 要不捲就點得到")
            }
        }

        // 鍵盤輸入由 Purrdr 的輸入元件接管(#136):它是焦點，打字、按鍵列、收起與叫出鍵盤照常。
        step("鍵盤輸入由終端機輸入元件接管") {
            let input = app.descendants(matching: .any)["terminal.input"].firstMatch
            XCTAssertTrue(input.waitUntilExists(timeout: 5), "沒有終端機輸入元件")
            XCTAssertEqual(input.value(forKey: "hasKeyboardFocus") as? Bool, true, "輸入元件要是焦點")

            app.typeEnglish("s")  // 前一段已打了 l
            screen.expectValue(containing: "demo@purrdr ledger % ls")
            app.buttons["terminal.key.esc"].firstMatch.tap()
            screen.expectValue(containing: "ls^[")

            let keyboard = app.buttons["terminal.key.keyboard"].firstMatch
            keyboard.tap()
            XCTAssertEqual(keyboard.label, "Show Keyboard")
            XCTAssertEqual(input.value(forKey: "hasKeyboardFocus") as? Bool, false, "收起鍵盤後輸入元件不是焦點")
            keyboard.tap()
            XCTAssertEqual(input.value(forKey: "hasKeyboardFocus") as? Bool, true, "叫出鍵盤後輸入元件回到焦點")
            app.typeEnglish("x")
            screen.expectValue(containing: "ls^[x")
        }

        step("Ctrl 鎖定不只靠顏色，送出 ^C 後放開") {
            let ctrl = app.buttons["terminal.key.ctrl"].firstMatch
            ctrl.tap()
            // VoiceOver 讀得到「Locked」並帶 selected 特性(畫面上另有「•」,由按鍵本身的文字呈現)。
            XCTAssertEqual(ctrl.value as? String, "Locked")
            XCTAssertTrue(ctrl.isSelected, "Ctrl 鎖定要有 selected 特性")

            app.typeEnglish("c")
            screen.expectValue(containing: "^C")
            XCTAssertEqual(ctrl.value as? String, "Off", "送出後 Ctrl 要放開")
        }
    }

    /// 注音組字(#140):浮層出現在游標格子、念得出組字文字，確認前不送;放棄組字後浮層消失。
    @MainActor
    func testZhuyinCompositionShowsOverlayAtCursor() throws {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleKeyboards", "(zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic)"])
        let screen = openTerminal(app)
        screen.expectValue(containing: "demo@purrdr ledger %")
        let input = app.descendants(matching: .any)["terminal.input"].firstMatch
        XCTAssertTrue(input.waitUntilExists(timeout: 5), "沒有終端機輸入元件")
        XCTAssertTrue(input.wait(timeout: 5) { ($0.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "輸入元件沒有取得焦點")
        // 以實體鍵盤的注音配置按鍵組字：模擬器沒有接實體鍵盤(畫面上有軟體鍵盤)時測不到，略過(#374)。
        if app.keyboards.firstMatch.waitUntilExists(timeout: 2) {
            throw XCTSkip("需要模擬器接著實體鍵盤(Simulator ▸ I/O ▸ Keyboard ▸ Connect Hardware Keyboard)")
        }
        app.switchKeyboard(to: .zhuyin)

        // 模擬器接著實體鍵盤，軟體鍵盤在畫面外;以注音的實體鍵盤配置按 s、u、3(ㄋ、ㄧ、ˇ)。typeText 不經過輸入法。
        for key in ["s", "u", "3"] {
            app.typeKey(key, modifierFlags: [])
        }

        let overlay = app.descendants(matching: .any)["terminal.composition"].firstMatch
        XCTAssertTrue(overlay.waitUntilExists(timeout: 5), "組字時沒有浮層")
        XCTAssertEqual(overlay.value as? String, "ㄋㄧˇ")
        // 輸入元件的無障礙範圍以游標格子為中心撐到 44×44pt(#249),比對中心：游標格子的中心落在浮層第一格裡(#251)。
        // 終端機畫面剛開時還在重排，輸入元件跟著游標移動：等它與浮層在同一列再量(完整跑時量到過移動前的位置)。
        _ = UITestWait.until(timeout: 5) { abs(overlay.frame.midY - input.frame.midY) <= 1 }
        let cursorOffset = input.frame.midX - overlay.frame.minX
        XCTAssertTrue((0...12).contains(cursorOffset), "浮層要從游標格子開始(游標中心在浮層左緣右邊 \(cursorOffset)pt)")
        XCTAssertEqual(overlay.frame.midY, input.frame.midY, accuracy: 1, "浮層要在游標那一列")
        XCTAssertFalse((screen.value as? String)?.contains("ㄋ") == true, "確認前不能送出注音")

        // 模擬器的注音輸入法不會出候選字，改用按鍵列結束組字：先放棄組字(浮層消失)再送 Esc。
        app.buttons["terminal.key.esc"].firstMatch.tap()
        XCTAssertTrue(overlay.waitUntilGone(timeout: 5), "放棄組字後浮層要消失")
        screen.expectValue(containing: "demo@purrdr ledger % ^[")
        XCTAssertFalse((screen.value as? String)?.contains("ㄋ") == true, "放棄的注音不能送出")
    }

    /// 只在畫面顯示時持有 Pane 的尺寸(#357):進背景(鎖定也是)放開控制,回到前景自動以手機的格數重新接上,不必按「重新連線」。
    @MainActor
    func testReturningFromBackgroundReappliesControl() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)
        screen.expectValue(containing: "demo@purrdr ledger %")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "沒有進背景")
        app.activate()

        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        XCTAssertTrue(status.waitUntilExists(timeout: 10))
        XCTAssertTrue(status.wait(timeout: 10) { $0.label.contains("Connected") }, "回到前景沒有自動接回:\(status.label)")
        XCTAssertFalse(app.buttons["terminal.reconnect"].exists, "自己放開的，回來不該要使用者按「重新連線」")
        screen.expectValue(containing: "demo@purrdr ledger %")
    }

    @MainActor
    func testPaneInUseOffersTakeOver() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoPaneInUse"])
        let screen = openTerminal(app)

        let takeOver = app.buttons["terminal.takeOver"].firstMatch
        XCTAssertTrue(takeOver.waitUntilExists(timeout: 10), "被佔用時沒有「接管」")
        XCTAssertTrue(app.descendants(matching: .any)["terminal.status"].firstMatch.label.contains("In Use Elsewhere"))
        XCTAssertTrue(app.staticTexts["Someone is using this on the host. Tap Take Over to use it here."].firstMatch.exists, "沒有說明主機正在操作")

        takeOver.tap()
        screen.expectValue(containing: "demo@purrdr ledger %")
        XCTAssertFalse(takeOver.exists, "接上後「接管」要消失")
    }
}
