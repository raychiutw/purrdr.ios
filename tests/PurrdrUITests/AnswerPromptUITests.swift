import XCTest

/// 回答「需要你」(行為規格 F8、§5;HIG 20.7)。資料來自 Demo 主機的情境(`DemoAnswers`),走正式程式路徑。
final class AnswerPromptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func open(paneID: String) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.\(paneID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
        row.tap()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let field = element("composer.text", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "沒有輸入框")
        field.tap()
        field.typeText(text)
        element("composer.send", in: app).tap()
    }

    /// weather-app 卡在 Bash 權限：卡片顯示問題、細節與選項(同尺寸、≥44pt);點「Yes」後清楚顯示選了什麼。
    @MainActor
    func testAnsweringBashPermission() {
        let app = open(paneID: "w2:p1")
        let card = element("prompt.card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "沒有提示卡")
        XCTAssertTrue(app.staticTexts["Do you want to proceed?"].exists, "沒有問題文字")
        XCTAssertTrue(app.staticTexts["Bash command"].exists, "沒有權限細節的標題")

        let yes = element("prompt.option.1", in: app)
        let no = element("prompt.option.3", in: app)
        XCTAssertTrue(yes.exists)
        XCTAssertGreaterThanOrEqual(yes.frame.height, 44, "選項觸控目標不足 44pt")
        XCTAssertEqual(yes.frame.width, no.frame.width, accuracy: 1, "同一組選項應同尺寸")

        yes.tap()

        let answered = element("prompt.answered", in: app)
        XCTAssertTrue(answered.waitForExistence(timeout: 10), "沒有顯示已回答")
        XCTAssertTrue(answered.label.contains("You chose: Yes"), "沒有寫出選了什麼:\(answered.label)")
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "回答後提示卡應消失")
    }

    /// 「ask me」:兩題 AskUserQuestion 逐題作答，再到檢閱畫面送出。
    @MainActor
    func testAskUserQuestionStepByStep() {
        let app = open(paneID: "w1:p1")
        send("ask me", in: app)

        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].waitForExistence(timeout: 15), "沒有第一題")
        element("prompt.option.2", in: app).tap()
        XCTAssertTrue(app.staticTexts["How large should the chart be?"].waitForExistence(timeout: 10), "沒有第二題")
        element("prompt.option.1", in: app).tap()
        XCTAssertTrue(app.staticTexts["Ready to submit your answers?"].waitForExistence(timeout: 10), "沒有檢閱畫面")
        element("prompt.option.1", in: app).tap()

        let answered = element("prompt.answered", in: app)
        XCTAssertTrue(element("prompt.card", in: app).waitForNonExistence(timeout: 10), "送出後提示卡應消失")
        XCTAssertTrue(answered.label.contains("Submit answers"), "沒有寫出最後的選擇:\(answered.label)")
    }

    /// 「trust」:資料夾信任(agent 仍回報閒置)。送出被拒後顯示提示;「Yes」不是預設選項，點了送方向鍵而不是單按 Enter。
    @MainActor
    func testFolderTrustPrompt() {
        let app = open(paneID: "w1:p1")
        send("trust", in: app)
        send("hello", in: app)

        let yes = element("prompt.option.label:Yes, I trust this folder", in: app)
        XCTAssertTrue(yes.waitForExistence(timeout: 15), "沒有資料夾信任的選項")
        XCTAssertTrue(app.staticTexts["Trust /Users/demo/ledger? Claude Code will be able to read, edit, and run files there."].exists)
        yes.tap()

        let answered = element("prompt.answered", in: app)
        XCTAssertTrue(answered.waitForExistence(timeout: 10), "沒有顯示已回答")
        XCTAssertTrue(answered.label.contains("Yes, I trust this folder"))
    }
}
