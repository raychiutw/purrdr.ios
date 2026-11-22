import XCTest

/// 回答「需要你」(行為規格 F8、§5;HIG 20.7)。資料來自 Demo 主機的情境(`DemoAnswers`),走正式程式路徑。
final class AnswerPromptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.element("composer.text")
        XCTAssertTrue(field.waitUntilExists(timeout: 10), "沒有輸入框")
        field.tap()
        field.typeEnglish(text)
        app.element("composer.send").tap()
        // 收起鍵盤：鍵盤開著時可見範圍很小，選項會被註記卡片與輸入列蓋住，點到的是註記的動作(#251)。
        app.dismissKeyboard()
    }

    /// weather-app 卡在 Bash 權限：卡片顯示問題、細節與選項(同尺寸、≥44pt);點「Yes」後清楚顯示選了什麼。
    @MainActor
    func testAnsweringBashPermission() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")
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

        yes.tap()

        let answered = app.element("prompt.answered")
        XCTAssertTrue(answered.waitUntilExists(timeout: 10), "沒有顯示已回答")
        XCTAssertTrue(answered.label.contains("You chose: Yes"), "沒有寫出選了什麼:\(answered.label)")
        XCTAssertTrue(card.waitUntilGone(timeout: 10), "回答後提示卡應消失")
    }

    /// 選項是同寬的圓角長方形選項卡，長文字多行完整顯示(#93)。外觀以截圖附件確認。
    @MainActor
    func testLongOptionWrapsOnMultipleLines() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")
        let card = app.element("prompt.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 10), "沒有提示卡")
        let short = app.element("prompt.option.1")
        let long = app.element("prompt.option.2")
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
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        send("ask me", in: app)

        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].waitUntilExists(timeout: 15), "沒有第一題")
        app.element("prompt.option.2").tap()
        XCTAssertTrue(app.staticTexts["How large should the chart be?"].waitUntilExists(timeout: 10), "沒有第二題")
        app.element("prompt.option.1").tap()
        XCTAssertTrue(app.staticTexts["Ready to submit your answers?"].waitUntilExists(timeout: 10), "沒有檢閱畫面")
        let submit = app.element("prompt.option.1")
        XCTAssertTrue(submit.waitUntilExistsAndSettled(timeout: 5))
        submit.tap()

        let answered = app.element("prompt.answered")
        XCTAssertTrue(app.element("prompt.card").waitUntilGone(timeout: 10), "送出後提示卡應消失")
        XCTAssertTrue(answered.label.contains("Submit answers"), "沒有寫出最後的選擇:\(answered.label)")
    }

    /// 「Type something.」(#120):點了以後輸入框取得焦點、提示改成打回答;送出後進到下一題並寫出打的字。
    /// 取消回到一般輸入，問題卡還在。
    @MainActor
    func testTypeSomethingAnswersWithComposer() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        send("ask me", in: app)
        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].waitUntilExists(timeout: 15), "沒有第一題")

        let typeSomething = app.element("prompt.option.4")
        XCTAssertTrue(typeSomething.isEnabled, "「Type something.」應可點")
        typeSomething.tap()
        let banner = app.element("composer.typedAnswer")
        XCTAssertTrue(banner.waitUntilExists(timeout: 5), "沒有顯示正在打自訂回答")
        XCTAssertTrue(app.waitForKeyboard(), "輸入框應取得焦點")
        XCTAssertEqual(app.element("composer.text").label, "Type your answer", "提示應改成打回答")

        app.element("composer.typedAnswer.cancel").tap()
        XCTAssertTrue(banner.waitUntilGone(timeout: 5), "取消後應回到一般輸入")
        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].exists, "取消不應回答問題")

        // 取消後選項列隨輸入列重排：等位置停下再點。
        app.waitForSettledLayout([typeSomething], timeout: 3)
        // 取消後卡片還在重排時點擊可能被吃掉：點到自訂回答的橫幅出現為止。
        for _ in 0..<3 where !banner.exists {
            typeSomething.tap()
            _ = banner.waitUntilExists(timeout: 3)
        }
        XCTAssertTrue(banner.exists)
        app.element("composer.text").typeEnglish("Forest green")
        app.element("composer.send").tap()

        XCTAssertTrue(app.staticTexts["How large should the chart be?"].waitUntilExists(timeout: 10), "自訂回答後應進到第二題")
        let answered = app.element("prompt.answered")
        XCTAssertTrue(answered.label.contains("Forest green"), "沒有寫出打的回答:\(answered.label)")
    }

    /// 「trust」:資料夾信任(agent 仍回報閒置)。送出被拒後顯示提示;「Yes」不是預設選項，點了送方向鍵而不是單按 Enter。
    @MainActor
    func testFolderTrustPrompt() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        send("trust", in: app)
        send("hello", in: app)

        let yes = app.element("prompt.option.label:Yes, I trust this folder")
        XCTAssertTrue(yes.waitUntilExists(timeout: 15), "沒有資料夾信任的選項")
        XCTAssertTrue(app.staticTexts["Trust /Users/demo/ledger? Claude Code will be able to read, edit, and run files there."].exists)
        yes.tap()

        let answered = app.element("prompt.answered")
        XCTAssertTrue(answered.waitUntilExists(timeout: 10), "沒有顯示已回答")
        XCTAssertTrue(answered.label.contains("Yes, I trust this folder"))
    }
}
