import XCTest

/// 回答「需要你」(行為規格 F8、§5;HIG 20.7)。資料來自 Demo 主機的情境(`DemoAnswers`),走正式程式路徑。
final class AnswerPromptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func open(paneID: String) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
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

    /// 選項是同寬的圓角長方形選項卡，長文字多行完整顯示(#93)。外觀以截圖附件確認。
    @MainActor
    func testLongOptionWrapsOnMultipleLines() {
        let app = open(paneID: "w2:p1")
        let card = element("prompt.card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "沒有提示卡")
        let short = element("prompt.option.1", in: app)
        let long = element("prompt.option.2", in: app)
        XCTAssertTrue(long.exists)
        XCTAssertEqual(short.frame.width, long.frame.width, accuracy: 1, "同一組選項應同寬")
        XCTAssertGreaterThan(long.frame.height, short.frame.height + 10, "長選項應多行顯示，不截斷")
        XCTAssertTrue(long.label.contains("/Users/demo/weather-app"), "長選項的朗讀內容應完整:\(long.label)")

        let shot = XCTAttachment(screenshot: card.screenshot())
        shot.name = "prompt-options"
        shot.lifetime = .keepAlways
        add(shot)
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

    /// 「Type something.」(#120):點了以後輸入框取得焦點、提示改成打回答;送出後進到下一題並寫出打的字。
    /// 取消回到一般輸入，問題卡還在。
    @MainActor
    func testTypeSomethingAnswersWithComposer() {
        let app = open(paneID: "w1:p1")
        send("ask me", in: app)
        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].waitForExistence(timeout: 15), "沒有第一題")

        let typeSomething = element("prompt.option.4", in: app)
        XCTAssertTrue(typeSomething.isEnabled, "「Type something.」應可點")
        typeSomething.tap()
        let banner = element("composer.typedAnswer", in: app)
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "沒有顯示正在打自訂回答")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "輸入框應取得焦點")
        XCTAssertEqual(element("composer.text", in: app).label, "Type your answer", "提示應改成打回答")

        element("composer.typedAnswer.cancel", in: app).tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5), "取消後應回到一般輸入")
        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].exists, "取消不應回答問題")

        typeSomething.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        element("composer.text", in: app).typeText("Forest green")
        element("composer.send", in: app).tap()

        XCTAssertTrue(app.staticTexts["How large should the chart be?"].waitForExistence(timeout: 10), "自訂回答後應進到第二題")
        let answered = element("prompt.answered", in: app)
        XCTAssertTrue(answered.label.contains("Forest green"), "沒有寫出打的回答:\(answered.label)")
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
