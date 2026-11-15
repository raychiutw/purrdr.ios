import XCTest

/// 對話閱讀(行為規格 F5)。資料來自 Demo 主機的 Claude Code 對話紀錄，走正式程式路徑。
final class ConversationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openLedger() -> XCUIApplication {
        open(paneID: "w1:p1")
    }

    @MainActor
    private func open(paneID: String) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
        row.tap()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 點開 Agent 看到對話：使用者泡泡、工具串摘要、已載入 skill、agent 的 markdown 回覆。
    @MainActor
    func testOpeningAgentShowsConversation() {
        let app = openLedger()

        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10), "沒有使用者泡泡")
        XCTAssertTrue(app.staticTexts["Loaded skill: tdd"].exists, "skill 沒有顯示成「Loaded skill」")
        XCTAssertTrue(app.staticTexts["Ran 1 command · Edited 1 file · Read 1 file"].exists, "工具串沒有收合成一行摘要")
        XCTAssertTrue(element("conversation.table", in: app).exists, "沒有表格")
        XCTAssertTrue(element("conversation.beginning", in: app).exists, "頂端沒有「對話開頭」")
    }

    /// 只有 http(s) 連結可點;file:// 連結只留文字(R-V03)。
    @MainActor
    func testOnlyWebLinksAreLinks() {
        let app = openLedger()
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10))

        XCTAssertTrue(app.links["RFC 4180"].waitForExistence(timeout: 5), "https 連結不可點")
        XCTAssertFalse(app.links["the README"].exists, "file:// 連結不該可點")
    }

    /// 程式碼區塊有複製鈕(document.on.document,有 label),且在自己的容器內可橫捲。
    @MainActor
    func testCodeBlockHasCopyButton() {
        let app = openLedger()

        let copy = element("conversation.code.copy", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "程式碼區塊沒有複製鈕")
        XCTAssertEqual(copy.label, "Copy Code")
        XCTAssertGreaterThanOrEqual(copy.frame.width, 44)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertTrue(app.scrollViews["conversation.code"].exists, "程式碼區塊不在自己的橫捲容器內")
    }

    /// 工具串點開看每個呼叫。
    @MainActor
    func testToolRunExpandsToShowCalls() {
        let app = openLedger()
        let summary = app.staticTexts["Ran 1 command · Edited 1 file · Read 1 file"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))

        summary.tap()

        XCTAssertTrue(app.staticTexts["Edit"].waitForExistence(timeout: 5), "展開後沒有看到每個呼叫")
    }

    // MARK: - 送出(F6)

    /// 送出：輸入框清空、回音出現;Demo 的 agent 收下後，對話紀錄接上這則訊息與回覆，回音換成對話紀錄的那則。
    @MainActor
    func testSendingEchoesAndAgentReplies() {
        let app = openLedger()
        let text = element("composer.text", in: app)
        let send = element("composer.send", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        XCTAssertFalse(send.isEnabled, "空白時送出鈕應停用")
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)

        text.tap()
        text.typeText("Add a header row too?")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertEqual(text.value as? String ?? "", "", "送出後輸入框應清空")
        XCTAssertTrue(app.staticTexts["Add a header row too?"].waitForExistence(timeout: 5), "沒有回音")
        let reply = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'This is the demo host'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "對話紀錄沒有接上 agent 的回覆")
        XCTAssertFalse(element("conversation.echo", in: app).exists, "對話紀錄確認後回音應消失")
    }

    /// 聚焦時有「收起鍵盤」:收起後草稿還在、沒有送出(#37 故事 36)。
    @MainActor
    func testHideKeyboardKeepsDraft() {
        let app = openLedger()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertFalse(element("composer.hideKeyboard", in: app).exists, "沒聚焦時不該有收起鍵盤鈕")

        text.tap()
        text.typeText("Half a thought")
        let hide = element("composer.hideKeyboard", in: app)
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "聚焦時沒有收起鍵盤鈕")
        XCTAssertEqual(hide.label, "Hide Keyboard")
        hide.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "鍵盤沒有收起")
        XCTAssertEqual(text.value as? String, "Half a thought", "草稿不見了")
        XCTAssertFalse(element("conversation.echo", in: app).exists, "收起鍵盤不該送出")
    }

    /// 「需要你」的 agent 拒收：草稿放回輸入框，提示先回答。
    @MainActor
    func testBlockedAgentKeepsDraftAndExplains() {
        let app = open(paneID: "w2:p1")
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("Go ahead")
        element("composer.send", in: app).tap()

        XCTAssertTrue(element("composer.notice", in: app).waitForExistence(timeout: 10), "沒有提示先回答")
        XCTAssertEqual(text.value as? String, "Go ahead", "被拒時草稿應放回輸入框")
    }
}
