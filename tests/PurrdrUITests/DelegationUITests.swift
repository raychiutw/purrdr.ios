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
        let row = app.descendants(matching: .any)["spaces.tab.demo/w2:t1"].firstMatch
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 weather-app Agent")
        row.tap()
        return app
    }

    /// 內容含某段文字的訊息(使用者泡泡或 agent 訊息;每則訊息合成一個元素，label 有作者前綴)。
    @MainActor
    private func message(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 打開 workflow 卡看到摘要與各 phase,每個 phase 列出其中的 agent,可再打開 agent 的對話(#37 故事 37,G25)。
    /// 返回後 subagent 卡片:顯示標題、類型 · 模型、時長 · tokens · 工具數;點本體展開結果;箭頭開唯讀的 subagent 畫面。
    /// 最後(會改狀態,放最後)weather-app 卡在 Bash 權限(行為規格 F8、§5;HIG 20.7):卡片顯示問題、細節與選項(同尺寸、≥44pt);
    /// 點「Yes」後清楚顯示選了什麼。
    @MainActor
    func testWorkflowScreenThenSubagentCardThenAnsweringBashPermission() {
        let app = openWeather()

        XCTAssertTrue(app.staticTexts["forecast-audit"].waitUntilExists(timeout: 10), "沒有 workflow 卡")
        XCTAssertTrue(app.staticTexts["1 of 3 agents done"].waitUntilExists(timeout: 10), "卡片沒有顯示 agent 進度")

        app.element("conversation.workflow.open").tap()
        XCTAssertTrue(app.element("workflow.summary").waitUntilExists(timeout: 10), "沒有打開 workflow 畫面")
        XCTAssertTrue(app.staticTexts["Check"].exists, "沒有 phase 標題")
        XCTAssertTrue(app.staticTexts["Review"].exists, "沒有第二個 phase")

        let agent = app.element("workflow.agent.aw0demo0000000001")
        XCTAssertTrue(agent.exists, "phase 裡沒有 agent 列")
        agent.tap()
        XCTAssertTrue(app.element("subagent.messages").waitUntilExists(timeout: 10), "沒有打開 workflow agent 的對話紀錄")
        XCTAssertTrue(message(containing: "Check that cached forecasts expire after an hour.", in: app).waitUntilExists(timeout: 5),
                      "agent 的對話紀錄內容不對")
        // agent 對話 → workflow 畫面 → 聊天。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("workflow.summary").waitUntilExists(timeout: 10), "返回後沒有回到 workflow 畫面")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("conversation.workflow.open").waitUntilExists(timeout: 10), "返回後沒有回到聊天")

        XCTAssertTrue(app.staticTexts["Check how the widget refreshes"].waitUntilExists(timeout: 10), "沒有 subagent 卡")
        XCTAssertTrue(app.staticTexts["Explore · sonnet"].exists, "說明行應是「類型 · 模型」")
        XCTAssertTrue(app.staticTexts["1m 6s · 21.5k tokens · 6 tool calls"].exists, "沒有時長 · tokens · 工具數")

        let subagentCard = app.element("conversation.subagent")
        subagentCard.waitUntilFrameStops()
        subagentCard.tap()
        XCTAssertTrue(app.element("conversation.subagent.result").waitUntilExists(timeout: 10), "點卡片沒有展開結果")

        let open = app.element("conversation.subagent.open")
        XCTAssertGreaterThanOrEqual(open.frame.width, 44)
        // 展開結果後對話跟著底部捲，箭頭可能被推到導覽列底下：捲回看得到再點。
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<6 where !open.isHittable || open.frame.minY < navigationBottom {
            app.conversationList.swipeDown(velocity: .slow)
        }
        open.tap()
        XCTAssertTrue(app.element("subagent.messages").waitUntilExists(timeout: 10), "沒有打開 subagent 畫面")
        // 每則訊息是一個 VoiceOver 元素(label 以「Agent:」開頭,#35),以內容比對。
        XCTAssertTrue(message(containing: "The timeline refreshes every 15 minutes and fetches each time.", in: app).waitUntilExists(timeout: 5),
                      "subagent 畫面沒有顯示它的對話紀錄")
        // subagent 畫面 → 聊天。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("prompt.card").waitUntilExists(timeout: 10), "返回後沒有回到聊天")

        let card = app.element("prompt.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 10), "沒有提示卡")
        XCTAssertTrue(app.staticTexts["Do you want to proceed?"].exists, "沒有問題文字")
        XCTAssertTrue(app.staticTexts["Bash command"].exists, "沒有權限細節的標題")

        let yes = app.element("prompt.option.1")
        let no = app.element("prompt.option.3")
        XCTAssertTrue(yes.exists)
        XCTAssertGreaterThanOrEqual(yes.frame.height, 44, "選項觸控目標不足 44pt")
        XCTAssertEqual(yes.frame.width, no.frame.width, accuracy: 1, "同一組選項應同尺寸")
        // #271(原型 purrdr-screens 定案版):選項不編號。
        XCTAssertEqual(yes.label, "Yes", "選項不該帶編號:\(yes.label)")
        // 選項是同寬的圓角長方形選項卡,長文字多行完整顯示(#93)。
        let long = app.element("prompt.option.2")
        XCTAssertTrue(long.exists)
        XCTAssertEqual(yes.frame.width, long.frame.width, accuracy: 1, "同一組選項應同寬")
        XCTAssertGreaterThan(long.frame.height, yes.frame.height + 10, "長選項應多行顯示，不截斷")
        XCTAssertTrue(long.label.contains("/Users/demo/weather-app"), "長選項的朗讀內容應完整:\(long.label)")

        yes.tap()

        let answered = app.element("prompt.answered")
        XCTAssertTrue(answered.waitUntilExists(timeout: 10), "沒有顯示已回答")
        XCTAssertTrue(answered.label.contains("You chose: Yes"), "沒有寫出選了什麼:\(answered.label)")
        XCTAssertTrue(card.waitUntilGone(timeout: 10), "回答後提示卡應消失")
    }
}
