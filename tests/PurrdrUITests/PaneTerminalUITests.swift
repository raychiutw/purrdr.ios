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
    func testTerminalBehaviorsThenReturningFromBackgroundReappliesControl() {
        let app = XCUIApplication.launchUITesting(flags: [.uiTestingOversizedClipboard])
        let screen = openTerminal(app)

        step("連線後標題列下方顯示狀態") {
            screen.expectValue(containing: "demo@purrdr ledger %")
            XCTAssertTrue(app.waitForTerminalHeader(containing: "Connected", timeout: 10), "狀態不對:\(app.terminalHeader)")
            XCTAssertTrue(app.terminalHeader.contains("Tidy up the CSV export"), "標題不對:\(app.terminalHeader)")
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

        // 貼上失敗的說明顯示在終端機上方、不彈 alert(#625、#626):`-uiTestingOversizedClipboard` 讓剪貼簿一開始就超過貼上上限
        // (旗標只放剪貼簿內容,前面的按鍵列步驟只讀貼上鍵的 label、不按)。
        step("超量貼上顯示頁內說明、不彈 alert") {
            app.buttons["terminal.key.paste"].firstMatch.tap()
            let notice = app.descendants(matching: .any)["terminal.notice"].firstMatch
            XCTAssertTrue(notice.waitUntilExists(timeout: 10), "貼上失敗沒有顯示頁內說明")
            XCTAssertFalse(app.alerts.firstMatch.exists, "貼上失敗不該彈 alert")
            app.buttons["Dismiss"].firstMatch.tap()
            XCTAssertTrue(notice.waitUntilGone(timeout: 5), "說明沒有關掉")
        }

        // 只在畫面顯示時持有 Pane 的尺寸(#357):進背景(鎖定也是)放開控制,回到前景自動以手機的格數重新接上,不必按「重新連線」。
        step("進背景再回前景自動接回") {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "沒有進背景")
            app.activate()

            XCTAssertTrue(app.waitForTerminalHeader(containing: "Connected", timeout: 10), "回到前景沒有自動接回:\(app.terminalHeader)")
            XCTAssertFalse(app.buttons["terminal.reconnect"].exists, "自己放開的，回來不該要使用者按「重新連線」")
            screen.expectValue(containing: "demo@purrdr ledger %")
        }
    }
}
