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
        // 上下版面的輸入列較高(#187),摘要可能在導覽列底下：一小段一小段往回捲，直到摘要在可見範圍上緣，展開的呼叫才看得到。
        let window = app.windows.firstMatch
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<6 where !summary.isHittable || summary.frame.minY < navigationBottom + 8 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26)))
        }

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

    /// 多行草稿時輸入框長高超過舊的 4 行上限(#137):7 行全部攤開、不內捲。
    @MainActor
    func testComposerGrowsBeyondFourLines() {
        let app = openLedger()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("1\n2")
        let twoLines = text.frame.height
        text.typeText("\n3")
        let lineHeight = text.frame.height - twoLines
        XCTAssertGreaterThan(lineHeight, 10, "第 3 行沒有長高")

        text.typeText("\n4\n5\n6\n7")
        let sevenLines = text.frame.height
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-seven-lines"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertGreaterThan(sevenLines, twoLines + lineHeight * 4.5, "7 行時只有 \(sevenLines)pt(2 行 \(twoLines)、行高 \(lineHeight))")
    }

    /// 上下版面(#187):整寬輸入框在上、按鈕列在下;閒置時就有兩行高，按鈕 ≥ 44pt。
    @MainActor
    func testComposerStacksFullWidthEditorAboveButtons() {
        let app = openLedger()
        let text = element("composer.text", in: app)
        let send = element("composer.send", in: app)
        let addImage = element("composer.addImage", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(addImage.exists, "沒有加入圖片鈕")
        attachScreenshot(of: app, named: "composer-idle")

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(text.frame.width, window.width - 64, "輸入框沒有整寬(\(text.frame.width) / \(window.width))")
        XCTAssertGreaterThanOrEqual(text.frame.height, 60, "閒置時不到兩行高(\(text.frame.height)pt)")
        XCTAssertGreaterThanOrEqual(send.frame.minY, text.frame.maxY - 1, "送出鈕要在輸入框下方")
        XCTAssertGreaterThanOrEqual(addImage.frame.minY, text.frame.maxY - 1, "加入圖片鈕要在輸入框下方")
        XCTAssertLessThan(addImage.frame.maxX, send.frame.minX, "加入圖片在左、送出在右")
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertGreaterThanOrEqual(addImage.frame.height, 44)

        text.tap()
        let hide = element("composer.hideKeyboard", in: app)
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "聚焦時沒有收起鍵盤鈕")
        XCTAssertGreaterThanOrEqual(hide.frame.minY, text.frame.maxY - 1, "收起鍵盤鈕要在按鈕列")
        XCTAssertLessThan(hide.frame.maxX, send.frame.minX + 1, "收起鍵盤鈕在送出鈕左邊")
        text.typeText("Line one\nLine two\nLine three\nLine four")
        attachScreenshot(of: app, named: "composer-multiline")
        XCTAssertGreaterThanOrEqual(send.frame.minY, text.frame.maxY - 1, "多行時送出鈕仍在輸入框下方")
    }

    /// 注音組字(#187):組字文字跟一般文字一樣換行，輸入框跟著長高;按鈕列留在下方。
    @MainActor
    func testZhuyinCompositionWrapsAndGrowsComposer() {
        let app = open(paneID: "w1:p1", flags: ["-AppleKeyboards", "(zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic)"])
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        let idleHeight = text.frame.height

        // 模擬器接著實體鍵盤：以注音的實體鍵盤配置按 s、u、3(ㄋ、ㄧ、ˇ)。typeText 不經過輸入法。
        for _ in 0..<24 {
            for key in ["s", "u", "3"] {
                app.typeKey(key, modifierFlags: [])
            }
        }
        attachScreenshot(of: app, named: "composer-composing")
        XCTAssertTrue((text.value as? String)?.contains("ㄋ") == true, "沒有在組字(\(String(describing: text.value)))")
        XCTAssertGreaterThan(text.frame.height, idleHeight + 30, "組字換行後沒有長高(\(idleHeight) → \(text.frame.height))")
        XCTAssertGreaterThanOrEqual(element("composer.send", in: app).frame.minY, text.frame.maxY - 1, "送出鈕要在輸入框下方")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 展開編輯(#142):聚焦時才有展開鈕;展開後是同一份草稿，收回保留在展開畫面打的字;
    /// 沒聚焦、超過 2 行時仍有展開鈕。
    @MainActor
    func testExpandedEditorKeepsDraftWhenCollapsed() {
        let app = openLedger()
        let text = element("composer.text", in: app)
        let expand = element("composer.expand", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertFalse(expand.exists, "沒聚焦、空白時不該有展開鈕")

        text.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "聚焦時沒有展開鈕")
        XCTAssertEqual(expand.label, "Expand")
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        text.typeText("1\n2\n3")
        expand.tap()

        let expanded = element("composer.expanded.text", in: app)
        XCTAssertTrue(expanded.waitForExistence(timeout: 5), "沒有開出展開畫面")
        XCTAssertEqual(expanded.value as? String, "1\n2\n3", "展開畫面不是同一份草稿")
        XCTAssertGreaterThan(expanded.frame.height, text.frame.height, "展開畫面的輸入框沒有比輸入列大")
        expanded.tap()
        expanded.typeText("\n4")
        element("composer.expanded.done", in: app).tap()

        XCTAssertTrue(expanded.waitForNonExistence(timeout: 5), "「完成」沒有收回")
        XCTAssertEqual(text.value as? String, "1\n2\n3\n4", "收回後草稿不見了")
        XCTAssertFalse(element("conversation.echo", in: app).exists, "收回不該送出")
        XCTAssertFalse(element("composer.hideKeyboard", in: app).exists, "收回後輸入列不該聚焦")
        XCTAssertTrue(expand.exists, "沒聚焦、4 行時應有展開鈕")
    }

    /// 在展開畫面送出(#142):回到對話、輸入列清空、有回音;鍵盤出現時送出與完成鈕在鍵盤上方。
    @MainActor
    func testSendingFromExpandedEditorReturnsToConversation() {
        let app = openLedger()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        element("composer.expand", in: app).tap()

        let expanded = element("composer.expanded.text", in: app)
        XCTAssertTrue(expanded.waitForExistence(timeout: 5), "沒有開出展開畫面")
        expanded.tap()
        expanded.typeText("Sent from the big editor")
        let send = element("composer.expanded.send", in: app)
        let done = element("composer.expanded.done", in: app)
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 5) {
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1, "送出鈕被鍵盤擋住")
            XCTAssertLessThanOrEqual(done.frame.maxY, keyboard.frame.minY + 1, "完成鈕被鍵盤擋住")
        }
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        send.tap()

        XCTAssertTrue(expanded.waitForNonExistence(timeout: 5), "送出後沒有回到對話")
        XCTAssertTrue(app.staticTexts["Sent from the big editor"].waitForExistence(timeout: 5), "沒有回音")
        XCTAssertEqual(text.value as? String ?? "", "", "送出後輸入框應清空")
    }

    /// AX 字級下長高不超過鍵盤上方可用高度的 40%,超過的在框內捲動(#137)。
    @MainActor
    func testComposerAtAccessibilitySizeStaysWithinAvailableHeight() {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        // AX5 時 ledger 在閒置組很下面，捲不到：從註記清單的「Go to Chat」進去(同無障礙稽核)。
        let summary = app.buttons["youShouldKnow.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        summary.tap()
        element("youShouldKnow.go.demo/w1:p1", in: app).tap()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("1\n2\n3\n4\n5\n6\n7\n8\n9\n10")
        // 模擬器接著硬體鍵盤時軟體鍵盤在畫面外，可見範圍到視窗底。
        let window = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        let visibleBottom = keyboard.exists ? min(keyboard.frame.minY, window.maxY) : window.maxY

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-ax5-ten-lines"
        shot.lifetime = .keepAlways
        add(shot)
        // 可用高度從狀態列下緣算，比可見範圍小;以可見範圍當上界只會放寬。
        let height = text.frame.height
        XCTAssertLessThanOrEqual(height, visibleBottom * 0.4 + 1, "輸入框 \(height)pt 超過可見範圍(\(visibleBottom)pt)的 40%")
        XCTAssertGreaterThan(height, 44 * 2, "AX 字級下多行沒有長高(\(height)pt)")
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
        // 輸入列是上下版面(#187)、比單行高，上方內容區的中心跟著往上。
        XCTAssertGreaterThan(spinner.midY, screen.height * 0.2, "轉圈沒有置中")
        XCTAssertLessThan(spinner.midY, screen.height * 0.7, "轉圈沒有置中")
    }
}
