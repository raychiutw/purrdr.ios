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
    private func open(paneID: String, flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting(flags: flags)
        let row = app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
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

        // 連結是系統連結藍(#93),以截圖附件確認。
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-links"
        shot.lifetime = .keepAlways
        add(shot)
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
        // agent 訊息是一個元素，label 以「Agent:」開頭(#35)。
        let reply = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'This is the demo host'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "對話紀錄沒有接上 agent 的回覆")
        XCTAssertFalse(element("conversation.echo", in: app).exists, "對話紀錄確認後回音應消失")
    }

    /// 建議提示詞(#123):ledger 完成時輸入列上方有 Claude Code 的建議;點了只填入輸入框、叫出鍵盤，不送出，
    /// 對話紀錄沒有新增。輸入框有字時建議不顯示。
    @MainActor
    func testSuggestionFillsComposerWithoutSending() {
        let app = openLedger()
        let suggestion = element("conversation.suggestion", in: app)
        let text = element("composer.text", in: app)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "沒有建議")
        XCTAssertEqual(suggestion.label, "Suggestion: Add a test for CSV export with commas in the memo")
        XCTAssertGreaterThanOrEqual(suggestion.frame.height, 44)

        suggestion.tap()

        XCTAssertEqual(text.value as? String, "Add a test for CSV export with commas in the memo", "輸入框不是建議文字")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "鍵盤沒有叫出來")
        XCTAssertTrue(suggestion.waitForNonExistence(timeout: 5), "輸入框有字時建議應收起")
        XCTAssertTrue(element("composer.send", in: app).isEnabled)
        XCTAssertFalse(element("conversation.echo", in: app).exists, "點建議不該送出")
        let sent = app.descendants(matching: .any).matching(identifier: "conversation.user")
            .matching(NSPredicate(format: "label CONTAINS 'commas in the memo'")).firstMatch
        XCTAssertFalse(sent.waitForExistence(timeout: 5), "對話紀錄不該新增訊息")
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

    /// 「Jump to Latest」只在不在底部時出現：開啟時(在底部)沒有;往上捲出現;自己捲回底部或點它都消失(#93)。
    @MainActor
    func testJumpToLatestOnlyWhenAwayFromBottom() {
        let app = open(paneID: "w2:p1")
        XCTAssertTrue(element("prompt.card", in: app).waitForExistence(timeout: 10), "沒有提示卡")
        let jump = element("conversation.jumpToLatest", in: app)
        let list = app.scrollViews.firstMatch
        XCTAssertFalse(jump.waitForExistence(timeout: 2), "在底部時不該顯示")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "往上捲後應顯示")

        for _ in 0..<4 { list.swipeUp() }
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "自己捲回底部後應隱藏")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "再往上捲應顯示")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "點了回到最新後應隱藏")
        XCTAssertTrue(element("prompt.option.3", in: app).isHittable, "回到底部後最後一個選項應可點")
    }

    /// #130:往上翻看舊訊息時 agent 一次寫出超過 64 KiB(`-demoLargeOutput`:開啟 8 秒後寫出 321 行):
    /// 畫面不空白，正在看的舊訊息還在原處，新訊息接在後面。
    @MainActor
    func testLargeOutputWhileReadingKeepsMessages() {
        let app = open(paneID: "w1:p1", flags: ["-demoLargeOutput"])
        let first = app.staticTexts["Tidy up the CSV export: dates first, and escape commas in notes."]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "對話沒有載入完成")
        let list = app.scrollViews.firstMatch
        let jump = element("conversation.jumpToLatest", in: app)
        for _ in 0..<4 { list.swipeDown() }
        XCTAssertTrue(element("conversation.beginning", in: app).waitForExistence(timeout: 5), "沒有翻到對話開頭")
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "往上翻後應是閱讀中")

        // 開啟後 8 秒寫出;已完成的 agent 每 4 秒輪詢一次。等寫出之後的兩次輪詢。
        Thread.sleep(forTimeInterval: 18)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-large-output-while-reading"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(first.exists && first.isHittable, "正在看的舊訊息不見了(畫面被取代或停在內容之外)")
        XCTAssertTrue(element("conversation.beginning", in: app).exists, "對話開頭不見了(改讀了新視窗)")
        XCTAssertTrue(jump.exists, "應仍在閱讀中")
        jump.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'I read all 160 export logs'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "新訊息沒有接在後面")
    }

    /// 畫面上看得到(可點)的訊息列：使用者泡泡、agent 文字、工具串、回音。
    @MainActor
    private func visibleMessageRows(in app: XCUIApplication) -> Int {
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["conversation.user", "conversation.agent", "conversation.toolRun", "conversation.echo"]))
        return rows.allElementsBoundByIndex.filter(\.isHittable).count
    }

    /// #130(使用者回報最常見的情況):長對話中送出 prompt 後，agent 立刻一次寫出超過 64 KiB
    /// (`-demoLargeOutputOnPrompt`)。送出時切回跟隨並捲到底，畫面不可變成一片空白，最新的訊息在畫面上。
    @MainActor
    func testSendingThenLargeOutputKeepsMessagesVisible() {
        let app = open(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        XCTAssertTrue(element("conversation.agent", in: app).waitForExistence(timeout: 10), "對話沒有載入完成")

        text.tap()
        text.typeText("Check the logs once more")
        element("composer.send", in: app).tap()
        let echo = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Check the logs once more'")).firstMatch
        XCTAssertTrue(echo.waitForExistence(timeout: 5), "沒有回音")
        // 回覆與大量輸出在下一次輪詢讀到(已完成的 agent 每 4 秒一次);等兩次輪詢與捲動穩定。
        Thread.sleep(forTimeInterval: 10)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-large-output-after-send"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertGreaterThan(visibleMessageRows(in: app), 0, "送出後畫面上沒有任何訊息列(空白)")
        let summaries = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'I read all 160 export logs'"))
        XCTAssertTrue(summaries.allElementsBoundByIndex.contains(where: \.isHittable), "跟隨中最新的訊息應在畫面上")
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

    /// 對話載入中(#114):輸入列與載入完成後在同一個位置(畫面底部),轉圈仍在輸入列上方的中段。
    @MainActor
    func testComposerStaysAtBottomWhileConversationLoads() {
        // 基準：同一台模擬器上載入完成後的輸入框位置(不寫死機型幾何)。
        let loaded = openLedger()
        XCTAssertTrue(element("conversation.user", in: loaded).waitForExistence(timeout: 10), "對話沒有載入完成")
        let loadedText = element("composer.text", in: loaded)
        XCTAssertTrue(loadedText.waitForExistence(timeout: 5), "載入完成後沒有輸入列")
        let expected = loadedText.frame
        loaded.terminate()

        // 對話紀錄的讀取有 20 秒期限(HostCommandDeadline.standard),期限到了就離開載入中：下面的等待合計在期限內，
        // 量完再確認仍在載入中，量到的才是載入中的位置。
        let app = open(paneID: "w1:p1", flags: ["-demoTranscriptPending"])
        let loading = element("conversation.loading", in: app)
        XCTAssertTrue(loading.waitForExistence(timeout: 10), "沒有停在載入中")
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 5), "載入中沒有輸入列")
        let actual = text.frame
        let spinner = loading.frame
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(loading.exists, "量測時已離開載入中(超過對話紀錄的讀取期限)")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-loading"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1, "載入中的輸入列不在載入完成後的位置(底緣 \(actual.maxY),應為 \(expected.maxY))")
        XCTAssertLessThan(spinner.maxY, actual.minY, "轉圈不在輸入列上方")
        XCTAssertGreaterThan(spinner.midY, screen.height * 0.3, "轉圈沒有置中")
        XCTAssertLessThan(spinner.midY, screen.height * 0.7, "轉圈沒有置中")
    }
}
