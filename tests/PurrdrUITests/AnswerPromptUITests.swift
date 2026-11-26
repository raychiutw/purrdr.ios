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

        // 接著第二題選選項 → 檢閱畫面送出(兩題 AskUserQuestion 逐題作答)。
        app.element("prompt.option.1").tap()
        XCTAssertTrue(app.staticTexts["Ready to submit your answers?"].waitUntilExists(timeout: 10), "沒有檢閱畫面")
        let submit = app.element("prompt.option.1")
        XCTAssertTrue(submit.waitUntilExistsAndSettled(timeout: 5))
        submit.tap()
        XCTAssertTrue(app.element("prompt.card").waitUntilGone(timeout: 10), "送出後提示卡應消失")
        XCTAssertTrue(answered.label.contains("Submit answers"), "沒有寫出最後的選擇:\(answered.label)")
    }
}
