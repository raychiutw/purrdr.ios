import XCTest

/// 問題卡顯示時叫出鍵盤(#680):問題卡要讓位，輸入列完整留在鍵盤上方。
/// 不看 `prompt.card` 的 frame(它是捲動內容的大小);以題目文字與輸入列元素的位置判斷。
final class QuestionCardKeyboardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func raiseQuestionCard(in app: XCUIApplication) {
        let field = app.element("composer.text")
        XCTAssertTrue(field.waitUntilExists(timeout: 10), "沒有輸入框")
        // AX 大字級下第一下點擊可能落在還在排版的輸入框上而沒拿到焦點:等焦點,沒有就再點一次(確定性等待,不固定 sleep)。
        for _ in 0..<3 {
            field.tap()
            if UITestWait.until(timeout: 3, { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }) { break }
        }
        field.typeEnglish("ask me")
        app.element("composer.send").tap()
        XCTAssertTrue(app.staticTexts["Which color should the chart use?"].waitUntilExists(timeout: 15), "沒有問題卡")
        app.dismissKeyboard()
    }

    @MainActor
    private func assertLayout(_ app: XCUIApplication, _ label: String) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(app.waitForKeyboard(), "\(label):沒有鍵盤")
        let card = app.element("composer.card")
        let send = app.element("composer.send")
        let question = app.element("prompt.question")
        XCTAssertTrue(card.waitUntilExists(timeout: 5), "\(label):沒有輸入卡片")
        XCTAssertTrue(question.exists, "\(label):題目不見了")
        // 等版面停住(鍵盤動畫與卡片縮小)。
        _ = app.waitForSettledLayout([card, question], timeout: 3)
        let keyboardTop = keyboard.frame.minY
        XCTAssertLessThanOrEqual(card.frame.maxY, keyboardTop + 1, "\(label):輸入列下緣被鍵盤蓋住 card=\(card.frame) keyboard=\(keyboard.frame)")
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboardTop + 1, "\(label):送出鈕被鍵盤蓋住 send=\(send.frame)")
        XCTAssertLessThanOrEqual(question.frame.maxY, card.frame.minY + 1, "\(label):問題卡蓋到輸入框 question=\(question.frame) card=\(card.frame)")
        let navBottom = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(question.frame.minY, navBottom - 1, "\(label):題目頂進導覽列 question=\(question.frame) nav=\(navBottom)")
        // 問題卡上方要留得出對話(下限是 minimumConversationHeight,XXL 約 80pt;這裡只擋「被擠光」)，不能整個畫面都是問題卡。
        XCTAssertGreaterThanOrEqual(question.frame.minY - navBottom, 60, "\(label):聊天訊息被問題卡擠掉 question=\(question.frame) nav=\(navBottom)")
    }

    @MainActor
    private func check(contentSize: String?, label: String) {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", contentSize: contentSize)
        raiseQuestionCard(in: app)
        app.element("composer.text").tap()
        assertLayout(app, label)
    }

    @MainActor func testDefaultSize() { check(contentSize: nil, label: "預設字級") }

    @MainActor func testExtraExtraLarge() {
        check(contentSize: "UICTContentSizeCategoryXXL", label: "XXL")
    }

    @MainActor func testAccessibilityLarge() {
        check(contentSize: "UICTContentSizeCategoryAccessibilityL", label: "AccessibilityL")
    }

    /// 模擬注音:先叫出問題卡,再切到另一個輸入法(有選字列、鍵盤較高);模擬器只有英文鍵盤時略過。
    @MainActor func testWithAlternateKeyboard() throws {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        raiseQuestionCard(in: app)
        app.element("composer.text").tap()
        XCTAssertTrue(app.waitForKeyboard(), "沒有鍵盤")
        let globe = app.buttons["Next keyboard"].firstMatch
        try XCTSkipUnless(globe.exists && globe.isHittable, "模擬器沒有第二個輸入法")
        globe.tap()
        _ = app.waitForSettledLayout([app.element("composer.card")], timeout: 3)
        assertLayout(app, "切換輸入法")
    }
}
