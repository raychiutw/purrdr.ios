import XCTest

/// Spaces／Agents 兩種檢視與 workspace 卡片(#40)。Demo 主機的 `notes`(w3)是 Codex + shell「npm run dev」,
/// 所以在 Spaces 是卡片;`ledger`(w1)、`weather-app`(w2)只有一個 agent,是聊天列。
final class SpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 預設是 Spaces:多 pane 的 workspace 是卡片(統計行)、下方有 agent 列與終端機列;點終端機列開它的 Pane 終端機。
    @MainActor
    func testSpacesShowsCardAndTerminalRowOpensTerminal() {
        let app = XCUIApplication.launchUITesting()

        let card = element("workspace.card.demo/w3", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "notes 沒有顯示成 workspace 卡片")
        XCTAssertTrue(app.navigationBars["Spaces"].exists, "大標題不是 Spaces")
        XCTAssertTrue(card.label.contains("1 agent, 1 working · 1 tab · 2 panes"), "統計行不對:\(card.label)")
        XCTAssertTrue(element("workspace.layout.demo/w3", in: app).exists, "卡片沒有版面圖按鈕")
        let agent = element("agent.row.demo/w3:p1", in: app)
        let terminal = element("terminal.row.demo/w3:p2", in: app)
        XCTAssertTrue(agent.exists, "卡片下方沒有 agent 列")
        XCTAssertTrue(terminal.exists, "卡片下方沒有終端機列")
        XCTAssertTrue(terminal.label.contains("npm run dev"), "終端機列副標沒有程式名:\(terminal.label)")
        XCTAssertLessThan(card.frame.minY, agent.frame.minY)
        XCTAssertLessThan(agent.frame.minY, terminal.frame.minY)
        // ledger 在閒置組，落在 notes 卡片下方(列表是 lazy,要捲到才存在)。
        XCTAssertTrue(app.reveal(element("agent.row.demo/w1:p1", in: app)), "單一 agent 的 workspace 沒有聊天列")

        terminal.tap()
        let status = element("terminal.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "點終端機列沒有開 Pane 終端機")
        XCTAssertTrue(status.label.contains("npm run dev"), "終端機標題不是程式名:\(status.label)")
    }

    /// 點卡片本身開版面圖;點版面圖的終端機方塊開該 Pane 的終端機(#40 補充)。
    @MainActor
    func testCardOpensLayoutAndShellBlockOpensTerminal() {
        let app = XCUIApplication.launchUITesting()
        let card = element("workspace.card.demo/w3", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        card.tap()
        let shellBlock = app.buttons["layout.block.w3:p2"]
        XCTAssertTrue(shellBlock.waitForExistence(timeout: 5), "點卡片沒有開版面圖")
        shellBlock.tap()

        let status = element("terminal.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "點終端機方塊沒有開 Pane 終端機")
        XCTAssertTrue(status.label.contains("npm run dev"), "終端機標題不是程式名:\(status.label)")
    }

    /// 點大標題切到 Agents:每個 agent 一列，沒有卡片與終端機列。
    @MainActor
    func testTitleMenuSwitchesToAgents() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(element("workspace.card.demo/w3", in: app).waitForExistence(timeout: 10))

        let bar = app.navigationBars["Spaces"]
        let title = bar.buttons["Spaces"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "標題不是檢視選單")
        title.tap()
        let agents = app.buttons["Agents"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "點大標題沒有切換選單")
        agents.tap()

        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "大標題沒有變成 Agents")
        XCTAssertTrue(element("agent.row.demo/w3:p1", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("workspace.card.demo/w3", in: app).exists, "Agents 檢視不該有卡片")
        XCTAssertFalse(element("terminal.row.demo/w3:p2", in: app).exists, "Agents 檢視不該有終端機列")
    }
}
