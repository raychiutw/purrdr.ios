import XCTest

/// Subagent 與 workflow 卡片(行為規格 F10、#37 G25)。Demo 主機 weather-app 聊天裡有一個已完成的 subagent 與一個
/// 執行中的 workflow,走正式的定位與讀取指令。
final class DelegationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openWeather() -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.demo/w2:p1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 weather-app Agent")
        row.tap()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 卡片顯示標題、類型 · 模型、時長 · tokens · 工具數;點本體展開結果;箭頭開唯讀的 subagent 畫面。
    @MainActor
    func testSubagentCardOpensTranscript() {
        let app = openWeather()

        XCTAssertTrue(app.staticTexts["Check how the widget refreshes"].waitForExistence(timeout: 10), "沒有 subagent 卡")
        XCTAssertTrue(app.staticTexts["Explore · sonnet"].exists, "說明行應是「類型 · 模型」")
        XCTAssertTrue(app.staticTexts["1m 6s · 21.5k tokens · 6 tool calls"].exists, "沒有時長 · tokens · 工具數")

        element("conversation.subagent", in: app).tap()
        XCTAssertTrue(element("conversation.subagent.result", in: app).waitForExistence(timeout: 5), "點卡片沒有展開結果")

        let open = element("conversation.subagent.open", in: app)
        XCTAssertGreaterThanOrEqual(open.frame.width, 44)
        open.tap()
        XCTAssertTrue(element("subagent.messages", in: app).waitForExistence(timeout: 10), "沒有打開 subagent 畫面")
        XCTAssertTrue(app.staticTexts["The timeline refreshes every 15 minutes and fetches each time."].waitForExistence(timeout: 5),
                      "subagent 畫面沒有顯示它的對話紀錄")
    }

    /// 打開 workflow 卡看到摘要與各 phase,每個 phase 列出其中的 agent,可再打開 agent 的對話(#37 故事 37,G25)。
    @MainActor
    func testWorkflowScreenShowsPhasesAndAgents() {
        let app = openWeather()

        XCTAssertTrue(app.staticTexts["forecast-audit"].waitForExistence(timeout: 10), "沒有 workflow 卡")
        XCTAssertTrue(app.staticTexts["1 of 3 agents done"].waitForExistence(timeout: 10), "卡片沒有顯示 agent 進度")

        element("conversation.workflow.open", in: app).tap()
        XCTAssertTrue(element("workflow.summary", in: app).waitForExistence(timeout: 10), "沒有打開 workflow 畫面")
        XCTAssertTrue(app.staticTexts["Check"].exists, "沒有 phase 標題")
        XCTAssertTrue(app.staticTexts["Review"].exists, "沒有第二個 phase")

        let agent = element("workflow.agent.aw0demo0000000001", in: app)
        XCTAssertTrue(agent.exists, "phase 裡沒有 agent 列")
        agent.tap()
        XCTAssertTrue(element("subagent.messages", in: app).waitForExistence(timeout: 10), "沒有打開 workflow agent 的對話紀錄")
        XCTAssertTrue(app.staticTexts["Check that cached forecasts expire after an hour."].exists, "agent 的對話紀錄內容不對")
    }
}
