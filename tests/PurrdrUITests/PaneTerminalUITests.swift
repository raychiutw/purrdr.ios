import XCTest

/// Pane 終端機:Demo 主機的 Pane(回顯 shell,控制字元以 `^C`、`^[` 顯示)。
final class PaneTerminalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 從 Agent 對話標題列的終端機鈕，打開該 Agent 自己的 Pane(#37 故事 43)。
    @MainActor
    private func openTerminal(_ app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        let button = app.buttons["terminal.open"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "對話標題列沒有終端機鈕")
        button.tap()
        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "沒有打開終端機")
        return screen
    }

    @MainActor
    private func waitForScreen(_ screen: XCUIElement, toContain text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in (screen.value as? String)?.contains(text) == true }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10)
        XCTAssertEqual(found, .completed, "畫面沒有出現「\(text)」:\(screen.value ?? "nil")", file: file, line: line)
    }

    @MainActor
    func testTerminalConnectsAndShowsStatusUnderTitle() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)

        waitForScreen(screen, toContain: "demo@purrdr ledger %")
        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        XCTAssertTrue(status.label.contains("Tidy up the CSV export"), "標題不對:\(status.label)")
        XCTAssertTrue(status.label.contains("Connected"), "狀態不對:\(status.label)")
    }

    @MainActor
    func testKeyBarKeysAreLabeledAndAtLeast44Points() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)
        waitForScreen(screen, toContain: "demo@purrdr ledger %")

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

    /// 鍵盤輸入由 Purrdr 的輸入元件接管(#136):它是焦點，打字、按鍵列、收起與叫出鍵盤照常。
    @MainActor
    func testKeyboardInputIsTakenOverByTerminalInput() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)
        waitForScreen(screen, toContain: "demo@purrdr ledger %")

        let input = app.descendants(matching: .any)["terminal.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "沒有終端機輸入元件")
        XCTAssertEqual(input.value(forKey: "hasKeyboardFocus") as? Bool, true, "輸入元件要是焦點")

        app.typeText("ls")
        waitForScreen(screen, toContain: "demo@purrdr ledger % ls")
        app.buttons["terminal.key.esc"].firstMatch.tap()
        waitForScreen(screen, toContain: "ls^[")

        let keyboard = app.buttons["terminal.key.keyboard"].firstMatch
        keyboard.tap()
        XCTAssertEqual(keyboard.label, "Show Keyboard")
        XCTAssertEqual(input.value(forKey: "hasKeyboardFocus") as? Bool, false, "收起鍵盤後輸入元件不是焦點")
        keyboard.tap()
        XCTAssertEqual(input.value(forKey: "hasKeyboardFocus") as? Bool, true, "叫出鍵盤後輸入元件回到焦點")
        app.typeText("x")
        waitForScreen(screen, toContain: "ls^[x")
    }

    /// 注音軟體鍵盤組字(#140):浮層出現在游標格子、念得出組字文字，確認前不送，選字後才出現在命令列。
    @MainActor
    func testZhuyinCompositionShowsOverlayAtCursor() {
        let app = XCUIApplication.launchUITesting(flags: ["-AppleKeyboards", "(zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic)"])
        let screen = openTerminal(app)
        waitForScreen(screen, toContain: "demo@purrdr ledger %")
        let input = app.descendants(matching: .any)["terminal.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "沒有終端機輸入元件")

        for key in ["ㄋ", "ㄧ", "ˇ"] {
            let button = app.keys[key].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "鍵盤沒有「\(key)」鍵")
            button.tap()
        }

        let overlay = app.descendants(matching: .any)["terminal.composition"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "組字時沒有浮層")
        XCTAssertEqual(overlay.value as? String, "ㄋㄧˇ")
        XCTAssertEqual(overlay.frame.minX, input.frame.minX, accuracy: 1, "浮層要從游標格子開始")
        XCTAssertEqual(overlay.frame.minY, input.frame.minY, accuracy: 1, "浮層要在游標那一列")
        XCTAssertFalse((screen.value as? String)?.contains("ㄋ") == true, "確認前不能送出注音")

        let candidate = app.collectionViews.cells.containing(.staticText, identifier: "你").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "沒有「你」這個候選字")
        candidate.tap()
        waitForScreen(screen, toContain: "demo@purrdr ledger % 你")
        XCTAssertFalse(overlay.exists, "選字後浮層要消失")
    }

    @MainActor
    func testStickyControlIsShownWithoutColorAndSendsControlC() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)
        waitForScreen(screen, toContain: "demo@purrdr ledger %")

        let ctrl = app.buttons["terminal.key.ctrl"].firstMatch
        ctrl.tap()
        // 鎖定不只靠顏色:VoiceOver 讀得到「Locked」並帶 selected 特性(畫面上另有「•」,由按鍵本身的文字呈現)。
        XCTAssertEqual(ctrl.value as? String, "Locked")
        XCTAssertTrue(ctrl.isSelected, "Ctrl 鎖定要有 selected 特性")

        app.typeText("c")
        waitForScreen(screen, toContain: "^C")
        XCTAssertEqual(ctrl.value as? String, "Off", "送出後 Ctrl 要放開")

        app.buttons["terminal.key.esc"].firstMatch.tap()
        waitForScreen(screen, toContain: "^[")
    }

    /// 手指往下滑回看先前的輸出(Demo 的 Pane 依 terminal.scroll 捲主機端 scrollback),打字後回到最新(#88 故事 17、19)。
    @MainActor
    func testSwipingDownScrollsBackToEarlierOutput() {
        let app = XCUIApplication.launchUITesting()
        let screen = openTerminal(app)
        waitForScreen(screen, toContain: "Wrote export/ledger-2026-11.csv")
        XCTAssertFalse((screen.value as? String)?.contains("python export.py") == true, "一開始就看得到最上面，測不出捲動")

        for _ in 0..<8 where (screen.value as? String)?.contains("python export.py") != true {
            screen.swipeDown()
        }
        waitForScreen(screen, toContain: "python export.py")

        app.typeText("l")
        waitForScreen(screen, toContain: "demo@purrdr ledger % l")
    }

    @MainActor
    func testPaneInUseOffersTakeOver() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoPaneInUse"])
        let screen = openTerminal(app)

        let takeOver = app.buttons["terminal.takeOver"].firstMatch
        XCTAssertTrue(takeOver.waitForExistence(timeout: 10), "被佔用時沒有「接管」")
        XCTAssertTrue(app.descendants(matching: .any)["terminal.status"].firstMatch.label.contains("In Use Elsewhere"))

        takeOver.tap()
        waitForScreen(screen, toContain: "demo@purrdr ledger %")
        XCTAssertFalse(takeOver.exists, "接上後「接管」要消失")
    }
}
