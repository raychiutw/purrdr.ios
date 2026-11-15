import XCTest

/// Pane 終端機:Demo 主機的 Pane(回顯 shell,控制字元以 `^C`、`^[` 顯示)。
final class PaneTerminalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 從 Agent 對話標題列的終端機鈕，打開該 Agent 自己的 Pane(#37 故事 43)。
    @MainActor
    private func openTerminal(_ app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)["agent.row.w1:p1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
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
