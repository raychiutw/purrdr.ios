import XCTest

/// 對話閱讀(行為規格 F5)。資料來自 Demo 主機的 Claude Code 對話紀錄，走正式程式路徑。
final class ConversationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openLedger() -> XCUIApplication {
        XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
    }

    /// 送出的訊息：還沒確認的回音，或對話紀錄已確認的使用者泡泡(追蹤可能立刻讀到，#165)。
    @MainActor
    private func sentMessage(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 點開 Agent 看到對話：使用者泡泡、工具串摘要、已載入 skill、agent 的 markdown 回覆。
    @MainActor
    func testOpeningAgentShowsConversation() {
        let app = openLedger()

        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10), "沒有使用者泡泡")
        XCTAssertTrue(app.staticTexts["Loaded skill: tdd"].exists, "skill 沒有顯示成「Loaded skill」")
        XCTAssertTrue(app.staticTexts["Edited 1 file · 3 steps"].exists, "工具串沒有收合成一行摘要")
        XCTAssertTrue(app.element("conversation.table").exists, "沒有表格")
        XCTAssertTrue(app.element("conversation.beginning").exists, "頂端沒有「對話開頭」")
    }

    /// 只有 http(s) 連結可點;file:// 連結只留文字(R-V03)。
    @MainActor
    func testOnlyWebLinksAreLinks() {
        let app = openLedger()
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10))

        XCTAssertTrue(app.links["RFC 4180"].waitUntilExists(timeout: 5), "https 連結不可點")
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

        let copy = app.element("conversation.code.copy")
        XCTAssertTrue(copy.waitUntilExists(timeout: 10), "程式碼區塊沒有複製鈕")
        XCTAssertEqual(copy.label, "Copy Code")
        // 圓角框裁切後座標有浮點誤差(43.9999…),容許 0.01pt。
        XCTAssertGreaterThanOrEqual(copy.frame.width, 43.99)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 43.99)
        XCTAssertTrue(app.scrollViews["conversation.code"].exists, "程式碼區塊不在自己的橫捲容器內")
    }

    /// 表格與程式碼區塊不讓畫面橫捲(#351):框不超出視窗寬度，內容寬了在框內橫捲。
    @MainActor
    func testTableAndCodeStayWithinScreenWidth() {
        let app = openLedger()
        let window = app.windows.firstMatch
        let table = app.element("conversation.table")
        XCTAssertTrue(app.revealInConversation(table), "沒有表格")
        XCTAssertLessThanOrEqual(table.frame.maxX, window.frame.maxX + 1, "表格超出畫面右緣")
        XCTAssertGreaterThanOrEqual(table.frame.minX, window.frame.minX - 1, "表格超出畫面左緣")

        let code = app.scrollViews["conversation.code"]
        XCTAssertTrue(app.revealInConversation(code), "沒有程式碼區塊")
        XCTAssertLessThanOrEqual(code.frame.maxX, window.frame.maxX + 1, "程式碼區塊超出畫面右緣")
        XCTAssertGreaterThanOrEqual(code.frame.minX, window.frame.minX - 1, "程式碼區塊超出畫面左緣")
    }

    /// Agent 回覆每輪開頭有頭像與名稱，不包泡泡(#351);時間文字跟著 Dynamic Type(#258)。
    @MainActor
    func testAgentTurnStartsWithAvatarAndName() {
        let app = openLedger()
        let header = app.element("conversation.agent.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 10), "Agent 回覆開頭沒有頭像與名稱")
        XCTAssertTrue(app.staticTexts["Claude Code"].exists, "開頭沒有 Agent 名稱")
    }

    /// 工具串點開看每個呼叫。
    @MainActor
    func testToolRunExpandsToShowCalls() {
        let app = openLedger()
        let summary = app.staticTexts["Edited 1 file · 3 steps"]
        XCTAssertTrue(summary.waitUntilExists(timeout: 10))
        // 上下版面的輸入列較高(#187),摘要可能在導覽列底下：一小段一小段往回捲，直到摘要在可見範圍上緣，展開的呼叫才看得到。
        let window = app.windows.firstMatch
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<6 where !summary.isHittable || summary.frame.minY < navigationBottom + 8 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26)))
        }

        summary.tap()

        XCTAssertTrue(app.staticTexts["Edit"].waitUntilExists(timeout: 5), "展開後沒有看到每個呼叫")
    }

    // MARK: - 檔案情境(`-demoAgentFiles`:ledger 的對話換成寫檔、讀圖、提到主機路徑的一段)

    /// 開啟檔案情境的 ledger。
    @MainActor
    private func openAgentFiles() -> XCUIApplication {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoAgentFiles"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitUntilExists(timeout: 10), "對話沒有開啟")
        // 這裡看的是對話裡的卡片：先略過輸入列上方的註記，卡片才整張放得進可視區。
        dismissNote(in: app)
        return app
    }

    /// 略過 ledger 輸入列上方的 You should know 註記(第一次要同意)。
    @MainActor
    private func dismissNote(in app: XCUIApplication) {
        let note = app.element("youShouldKnow.note")
        XCTAssertTrue(note.waitUntilExists(timeout: 15), "ledger 沒有註記")
        app.buttons["youShouldKnow.dismiss"].tap()
        let allow = app.alerts.firstMatch.buttons["Allow"].firstMatch
        XCTAssertTrue(allow.waitUntilExists(timeout: 5), "略過註記沒有詢問同意")
        allow.tap()
        XCTAssertTrue(note.waitUntilGone(timeout: 10), "略過後註記沒有消失")
    }

    /// QuickLook 預覽的導覽列。iOS 27 的標題是不含副檔名的檔名(旁邊有選單箭頭),以開頭比對(#251)。
    @MainActor
    private func quickLookBar(named stem: String, in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", stem)).firstMatch
    }

    /// 關閉 QuickLook:iOS 27 是導覽列左上的 ✕(舊版是「Done」)。
    @MainActor
    private func closeQuickLook(_ bar: XCUIElement) {
        let done = bar.buttons["Done"].firstMatch
        (done.exists ? done : bar.buttons.firstMatch).tap()
    }

    /// 檔案卡片(#224):agent 改了 CSVExport.swift、新建了 CSVQuotingTests.swift(#228 另有 history.csv、draft.csv),
    /// 卡片標題念出動作、檔名、類型與路徑;內容來自對話紀錄，超過 8 行可展開。
    @MainActor
    func testWrittenFilesShowAsCards() {
        let app = openAgentFiles()
        let header = "conversation.agentFile.header"
        for prefix in ["Created file draft.csv", "Created file history.csv"] {
            XCTAssertTrue(app.revealInConversation(app.element(header, labelPrefix: prefix)), "沒有 \(prefix) 的卡片")
        }

        let created = app.element(header, labelPrefix: "Created file CSVQuotingTests.swift, Code")
        XCTAssertTrue(app.revealInConversation(created), "新建卡片標題不對")
        let edited = app.element(header, labelPrefix: "Edited file CSVExport.swift, Code")
        XCTAssertTrue(app.revealInConversation(edited), "修改卡片標題不對")
        XCTAssertTrue(edited.label.contains("1 lines added, 1 removed"), "\(edited.label)")
        XCTAssertFalse(edited.label.contains("Path:"), "路徑是進階資訊，收合時標題不念：\(edited.label)")

        // #330:路徑預設收起，點「Details」揭露控制才看到，再點收起。
        let path = "/Users/demo/ledger/Sources/Ledger/CSVExport.swift"
        let pathText = app.staticTexts[path]
        XCTAssertFalse(pathText.exists, "路徑不該預設顯示")
        let disclosures = app.descendants(matching: .any).matching(identifier: "conversation.agentFile.disclosure")
        let disclosure = disclosures.element(boundBy: 0)
        XCTAssertTrue(app.revealInConversation(disclosure), "沒有「Details」揭露控制")
        XCTAssertGreaterThanOrEqual(disclosure.frame.height, 43.9)
        disclosure.tap()
        XCTAssertTrue(app.element("conversation.agentFile.path").waitUntilExists(timeout: 3), "展開後沒有路徑")

        let toggle = app.element("conversation.agentFile.toggle")
        XCTAssertTrue(app.revealInConversation(toggle), "新建的測試檔超過 8 行，應該可以展開")
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        toggle.tap()
        let lastLine = app.staticTexts[#"    #expect(CSVExport.columns.first == "date")"#]
        XCTAssertTrue(app.revealInConversation(lastLine), "展開後沒有看到後面的行")
        XCTAssertEqual(toggle.label, "Show Less")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-file-cards"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 圖片卡片(#225):agent 讀了匯出預覽(小圖，自動從 Demo 主機載入縮圖)與掃描檔(超過 8 MiB,
    /// 顯示大小與「Load Image」,點了才載入)。點縮圖全螢幕看，「Done」關閉。
    @MainActor
    func testAgentImagesShowThumbnails() {
        let app = openAgentFiles()
        let previewHeader = app.element("conversation.agentImage.header", labelPrefix: "Read file export-preview.png, Image")
        XCTAssertTrue(app.revealInConversation(previewHeader), "沒有預覽圖的圖片卡片")

        let thumbnail = app.element("conversation.agentImage.thumbnail", labelPrefix: "Image export-preview.png")
        XCTAssertTrue(thumbnail.waitUntilExists(timeout: 15), "預覽圖沒有自動載入縮圖")
        XCTAssertTrue(app.revealInConversation(thumbnail))
        XCTAssertFalse(app.staticTexts["docs/export-preview.png"].exists)
        thumbnail.tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilExists(timeout: 5), "沒有全螢幕檢視")
        let done = app.element("agentImage.viewer.done")
        XCTAssertGreaterThanOrEqual(done.frame.height, 44)

        // #330:雙點兩下放大、再雙點兩下縮回;1× 下滑關閉。
        let image = app.element("agentImage.viewer.image")
        XCTAssertEqual(image.value as? String, "Not zoomed")
        image.doubleTap()
        let zoomed = waitForValue(of: image, beginning: "Zoomed in")
        XCTAssertTrue(zoomed?.hasPrefix("Zoomed in") == true, "雙點兩下沒有放大：\(String(describing: zoomed))")
        image.doubleTap()
        _ = waitForValue(of: image, beginning: "Not zoomed")
        XCTAssertEqual(image.value as? String, "Not zoomed", "再雙點兩下沒有縮回")
        let start = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilGone(timeout: 5), "1× 下滑沒有關閉")

        // 「Done」照舊可關閉。
        XCTAssertTrue(app.revealInConversation(thumbnail))
        thumbnail.tap()
        XCTAssertTrue(app.element("agentImage.viewer.done").waitUntilExists(timeout: 5))
        app.element("agentImage.viewer.done").tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilGone(timeout: 5))

        // 路徑收在揭露控制裡。
        let disclosure = app.element("conversation.agentImage.disclosure")
        XCTAssertTrue(app.revealInConversation(disclosure))
        disclosure.tap()
        XCTAssertTrue(app.element("conversation.agentImage.path").waitUntilExists(timeout: 3), "展開後沒有路徑")

        let load = app.element("conversation.agentImage.load")
        XCTAssertTrue(app.revealInConversation(load), "超過 8 MiB 的掃描檔應該等點擊")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Not loaded automatically")).firstMatch
        XCTAssertTrue(note.exists, "沒有顯示大小與說明")
        XCTAssertGreaterThanOrEqual(load.frame.height, 44)
        load.tap()
        let scan = app.element("conversation.agentImage.thumbnail", labelPrefix: "Image statement-scan.png")
        XCTAssertTrue(scan.waitUntilExists(timeout: 15), "點了之後掃描檔沒有載入")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-image-cards"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 點開檔案(#228):「Open」從 Demo 主機下載新建的測試檔，以 QuickLook 預覽;關閉後可以分享。
    @MainActor
    func testOpeningAFileShowsQuickLookAndShare() {
        let app = openAgentFiles()
        let open = app.buttons["Open CSVQuotingTests.swift"].firstMatch
        XCTAssertTrue(app.revealInConversation(open), "新建的測試檔沒有「Open」")
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        open.tap()

        let preview = quickLookBar(named: "CSVQuotingTests", in: app)
        XCTAssertTrue(preview.waitUntilExists(timeout: 15), "沒有出現 QuickLook 預覽")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-file-quicklook"
        shot.lifetime = .keepAlways
        add(shot)
        closeQuickLook(preview)
        XCTAssertTrue(preview.waitUntilGone(timeout: 5))

        let share = app.buttons["Share CSVQuotingTests.swift"].firstMatch
        XCTAssertTrue(app.revealInConversation(share), "下載好之後沒有「Share」")
        XCTAssertGreaterThanOrEqual(share.frame.height, 44)
    }

    /// 點開檔案(#228):匯出檔之後被附加到超過 25 MiB,顯示大小與說明，不下載。
    @MainActor
    func testOpeningAFileOverTheLimitExplains() {
        let app = openAgentFiles()
        let history = app.element("conversation.agentFile.header", labelPrefix: "Created file history.csv")
        XCTAssertTrue(app.revealInConversation(history), "沒有 history.csv 的卡片")
        history.tap()

        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Too large to open here")).firstMatch
        XCTAssertTrue(note.waitUntilExists(timeout: 10), "沒有超過上限的說明")
        XCTAssertTrue(note.label.contains("Open it on the host."))
    }

    /// 點開檔案(#228):草稿寫完被刪掉，顯示「主機上已沒有這個檔案」。
    @MainActor
    func testOpeningADeletedFileExplains() {
        let app = openAgentFiles()
        let open = app.buttons["Open draft.csv"].firstMatch
        XCTAssertTrue(app.revealInConversation(open), "沒有 draft.csv 的「Open」")
        open.tap()

        XCTAssertTrue(app.staticTexts["This file is no longer on the host."].waitUntilExists(timeout: 10), "沒有缺檔說明")
    }

    /// 訊息內主機路徑(#229):回覆提到報告 PDF 與預覽圖，路徑是連結;點 PDF 在 app 內以 QuickLook 開，
    /// 點圖片全螢幕看(不交給系統 openURL,沒有離開 app)。
    @MainActor
    func testHostPathsInMessagesOpenInApp() {
        let app = openAgentFiles()
        let report = app.links["/Users/demo/ledger/docs/export-report.pdf"].firstMatch
        XCTAssertTrue(app.revealInConversation(report), "訊息中的 PDF 路徑不是連結")
        report.tap()

        let preview = quickLookBar(named: "export-report", in: app)
        XCTAssertTrue(preview.waitUntilExists(timeout: 15), "點了路徑沒有出現 QuickLook 預覽")
        XCTAssertEqual(app.state, .runningForeground, "路徑不該交給系統開")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-host-path-quicklook"
        shot.lifetime = .keepAlways
        add(shot)
        closeQuickLook(preview)
        XCTAssertTrue(preview.waitUntilGone(timeout: 5))

        let image = app.links["/Users/demo/ledger/docs/export-preview.png"].firstMatch
        XCTAssertTrue(app.revealInConversation(image), "訊息中的圖片路徑不是連結")
        image.tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilExists(timeout: 10), "點了圖片路徑沒有全螢幕檢視")
        app.element("agentImage.viewer.done").tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilGone(timeout: 5))
    }

    // MARK: - 送出(F6)

    /// 送出：輸入框清空、回音出現;Demo 的 agent 收下後，對話紀錄接上這則訊息與回覆，回音換成對話紀錄的那則。
    @MainActor
    func testSendingEchoesAndAgentReplies() {
        let app = openLedger()
        let text = app.element("composer.text")
        let send = app.element("composer.send")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        XCTAssertFalse(send.isEnabled, "空白時送出鈕應停用")
        XCTAssertHitTarget(send)

        text.tap()
        text.typeEnglish("Add a header row too?")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertEqual(text.value as? String ?? "", "", "送出後輸入框應清空")
        // 軟體鍵盤＋You should know 卡片會把對話擠到不到一列：收起鍵盤，不依賴模擬器的鍵盤設定(#190)。
        app.dismissKeyboard()
        XCTAssertTrue(sentMessage("Add a header row too?", in: app).waitUntilExists(timeout: 5), "沒有回音")
        // agent 訊息是一個元素，label 以「Agent:」開頭(#35)。
        let reply = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'This is the demo host'")).firstMatch
        // 追蹤可能立刻讀到對話紀錄(#165):回音很快被確認，泡泡在對話裡(鍵盤與卡片之下不一定排版出來),所以回覆接上也算。
        let echoOrReply = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR (identifier == 'conversation.agent' AND label CONTAINS 'This is the demo host')",
            "Add a header row too?")).firstMatch
        XCTAssertTrue(echoOrReply.waitUntilExists(timeout: 5), "沒有回音")
        XCTAssertTrue(reply.waitUntilExists(timeout: 15), "對話紀錄沒有接上 agent 的回覆")
        XCTAssertFalse(app.element("conversation.echo").exists, "對話紀錄確認後回音應消失")
    }

    /// 送出可撤回(#300):送出後訊息先以倒數泡泡出現，撤回把文字放回輸入框;再送一次按「立即送出」就變成回音。
    @MainActor
    func testUndoSendRestoresDraftAndSendNowDelivers() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-uiTestingUndoSend"])
        let text = app.element("composer.text")
        let send = app.element("composer.send")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        text.tap()
        text.typeEnglish("Wait, not yet")
        send.tap()
        app.dismissKeyboard()

        let countdown = app.element("conversation.pendingSend.countdown")
        XCTAssertTrue(countdown.waitUntilExists(timeout: 5), "沒有倒數泡泡")
        XCTAssertTrue(countdown.label.hasPrefix("Sending in"), "倒數文字：\(countdown.label)")
        let undo = app.element("conversation.pendingSend.undo")
        XCTAssertHitTarget(undo)
        undo.tap()
        XCTAssertFalse(app.element("conversation.pendingSend").exists, "撤回後倒數泡泡應消失")
        XCTAssertEqual(text.value as? String, "Wait, not yet", "撤回應把文字放回輸入框")
        XCTAssertFalse(app.element("conversation.echo").exists, "撤回後不應有回音")

        send.tap()
        let sendNow = app.element("conversation.pendingSend.sendNow")
        XCTAssertTrue(sendNow.waitUntilExists(timeout: 5), "沒有立即送出")
        sendNow.tap()
        let echoOrReply = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR (identifier == 'conversation.agent' AND label CONTAINS 'This is the demo host')",
            "Wait, not yet")).firstMatch
        XCTAssertTrue(echoOrReply.waitUntilExists(timeout: 5), "立即送出後沒有回音")
        XCTAssertFalse(app.element("conversation.pendingSend").exists, "立即送出後倒數泡泡應消失")
    }

    /// 建議提示詞(#123):ledger 完成時輸入列上方有 Claude Code 的建議;點了只填入輸入框、叫出鍵盤，不送出，
    /// 對話紀錄沒有新增。輸入框有字時建議不顯示。註記的完整卡片在時建議卡不同時出現，先略過註記。
    @MainActor
    func testSuggestionFillsComposerWithoutSending() {
        let app = openLedger()
        dismissNote(in: app)
        let suggestion = app.element("conversation.suggestion")
        let text = app.element("composer.text")
        XCTAssertTrue(suggestion.waitUntilExists(timeout: 10), "沒有建議")
        XCTAssertEqual(suggestion.label, "Suggestion: Add a test for CSV export with commas in the memo, Fill In")
        XCTAssertGreaterThanOrEqual(suggestion.frame.height, 44)

        suggestion.tap()

        XCTAssertEqual(text.value as? String, "Add a test for CSV export with commas in the memo", "輸入框不是建議文字")
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        XCTAssertTrue(suggestion.waitUntilGone(timeout: 5), "輸入框有字時建議應收起")
        XCTAssertTrue(app.element("composer.send").isEnabled)
        XCTAssertFalse(app.element("conversation.echo").exists, "點建議不該送出")
        let sent = app.descendants(matching: .any).matching(identifier: "conversation.user")
            .matching(NSPredicate(format: "label CONTAINS 'commas in the memo'")).firstMatch
        XCTAssertFalse(sent.waitUntilExists(timeout: 5), "對話紀錄不該新增訊息")

        // 把字刪光：建議再出現(#240)。
        text.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60))
        XCTAssertTrue(suggestion.waitUntilExists(timeout: 5), "輸入框刪光後建議沒有再出現")
    }

    /// 軟體鍵盤出現時(#196):You should know 卡片讓位(收成一行或暫時拿掉),對話至少留 132pt、看得到訊息;
    /// 收起鍵盤後是一行(不在鍵盤動畫中長回來),點一行的註記才換回完整卡片。
    /// 模擬器接著硬體鍵盤(只有快捷列)時空間夠，卡片不收，這時不適用。
    @MainActor
    func testSoftKeyboardKeepsConversationVisible() throws {
        // iPhone 17 在預設字級與 AX1 都放得下完整註記與鍵盤(AX1 對話還剩約 135pt),不必讓位(#251);AX2 才要讓位。
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", contentSize: "UICTContentSizeCategoryAccessibilityL")
        let text = app.element("composer.text")
        XCTAssertTrue(app.element("youShouldKnow.note").waitUntilExists(timeout: 15), "沒有註記")
        XCTAssertFalse(app.element("conversation.suggestion").exists, "註記完整顯示時建議卡不該同時出現")
        text.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitUntilExists(timeout: 5), "鍵盤沒有叫出來")
        guard keyboard.frame.height > 150 else { throw XCTSkip("模擬器接著硬體鍵盤，沒有軟體鍵盤") }

        let compact = app.element("youShouldKnow.compact")
        // 讓位規則(#196):放得下一行就收成一行，連一行都放不下就暫時拿掉(AX2 的 iPhone 17 是後者)。
        XCTAssertTrue(app.element("youShouldKnow.note").waitUntilGone(timeout: 5), "鍵盤出現時完整卡片應讓位")
        text.typeEnglish("Typing while reading")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "soft-keyboard-typing"
        shot.lifetime = .keepAlways
        add(shot)

        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = [compact, app.element("conversation.suggestion")].filter(\.exists).map(\.frame.minY).min() ?? text.frame.minY
        XCTAssertGreaterThanOrEqual(bottom - top, 132, "對話只剩 \(bottom - top)pt")
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'conversation.agent' OR identifier == 'conversation.user'")).allElementsBoundByIndex
        XCTAssertTrue(rows.contains { $0.frame.maxY > top + 20 && $0.frame.minY < bottom - 20 }, "打字時看不到任何訊息")

        app.dismissKeyboard()
        XCTAssertTrue(compact.waitUntilExists(timeout: 5), "收起鍵盤時註記應回到一行(暫時拿掉的也回到一行)")
        compact.tap()
        XCTAssertTrue(app.element("youShouldKnow.note").waitUntilExists(timeout: 5), "點一行的註記後完整卡片沒有回來")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "點註記不該叫出鍵盤")
    }

    /// 聚焦時有「收起鍵盤」:收起後草稿還在、沒有送出(#37 故事 36)。
    @MainActor
    func testHideKeyboardKeepsDraft() {
        let app = openLedger()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        XCTAssertFalse(app.element("composer.hideKeyboard").exists, "沒聚焦時不該有收起鍵盤鈕")

        text.tap()
        text.typeEnglish("Half a thought")
        let hide = app.element("composer.hideKeyboard")
        XCTAssertTrue(hide.waitUntilExists(timeout: 5), "聚焦時沒有收起鍵盤鈕")
        XCTAssertEqual(hide.label, "Hide Keyboard")
        hide.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "鍵盤沒有收起")
        XCTAssertEqual(text.value as? String, "Half a thought", "草稿不見了")
        XCTAssertFalse(app.element("conversation.echo").exists, "收起鍵盤不該送出")
    }

    /// 送出後立刻收起鍵盤(#329)。
    @MainActor
    func testSendingDismissesKeyboard() {
        let app = openLedger()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        text.typeEnglish("Ship it")
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")

        app.element("composer.send").tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "送出後鍵盤沒有收起")
    }

    /// 點聊天的訊息區收起鍵盤(#329)。
    @MainActor
    func testTappingConversationDismissesKeyboard() {
        let app = openLedger()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "點訊息區後鍵盤沒有收起")
    }

    /// 上下滑動聊天收起鍵盤(#329)。
    @MainActor
    func testScrollingConversationDismissesKeyboard() {
        let app = openLedger()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(
            forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))

        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "滑動後鍵盤沒有收起")
    }

    /// 多行草稿時輸入框長高超過舊的 4 行上限(#137):7 行全部攤開、不內捲。
    @MainActor
    func testComposerGrowsBeyondFourLines() {
        let app = openLedger()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        text.typeEnglish("1\n2")
        let twoLines = text.frame.height
        text.typeEnglish("\n3")
        let lineHeight = text.frame.height - twoLines
        XCTAssertGreaterThan(lineHeight, 10, "第 3 行沒有長高")

        text.typeEnglish("\n4\n5\n6\n7")
        // 上限是鍵盤上方可用高度的 40%(#137):收起鍵盤再量，不依賴模擬器接的是軟體還是實體鍵盤(#190)。
        app.dismissKeyboard()
        let sevenLines = text.frame.height
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-seven-lines"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertGreaterThan(sevenLines, twoLines + lineHeight * 4.5, "7 行時只有 \(sevenLines)pt(2 行 \(twoLines)、行高 \(lineHeight))")
    }

    /// 上下版面(#187):整寬輸入框在上、按鈕列在下;空白時一行高(#196 留言)、打字後至少兩行高，按鈕 ≥ 44pt。
    @MainActor
    func testComposerStacksFullWidthEditorAboveButtons() {
        let app = openLedger()
        let text = app.element("composer.text")
        let send = app.element("composer.send")
        let addImage = app.element("composer.attach")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        XCTAssertTrue(addImage.exists, "沒有加入圖片鈕")
        attachScreenshot(of: app, named: "composer-idle")

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(text.frame.width, window.width - 64, "輸入框沒有整寬(\(text.frame.width) / \(window.width))")
        let emptyHeight = text.frame.height
        XCTAssertGreaterThanOrEqual(emptyHeight, 44, "空白時低於 44pt(\(emptyHeight)pt)")
        XCTAssertLessThan(emptyHeight, 60, "空白時應是一行高(\(emptyHeight)pt)")
        XCTAssertGreaterThanOrEqual(send.frame.minY, text.frame.maxY - 1, "送出鈕要在輸入框下方")
        XCTAssertGreaterThanOrEqual(addImage.frame.minY, text.frame.maxY - 1, "加入圖片鈕要在輸入框下方")
        XCTAssertLessThan(addImage.frame.maxX, send.frame.minX, "加入圖片在左、送出在右")
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertGreaterThanOrEqual(addImage.frame.height, 44)

        text.tap()
        let hide = app.element("composer.hideKeyboard")
        XCTAssertTrue(hide.waitUntilExists(timeout: 5), "聚焦時沒有收起鍵盤鈕")
        XCTAssertGreaterThanOrEqual(hide.frame.minY, text.frame.maxY - 1, "收起鍵盤鈕要在按鈕列")
        XCTAssertLessThan(hide.frame.maxX, send.frame.minX + 1, "收起鍵盤鈕在送出鈕左邊")
        text.typeEnglish("Line one")
        XCTAssertGreaterThanOrEqual(text.frame.height, 60, "有內容時不到兩行高(\(text.frame.height)pt)")
        text.typeEnglish("\nLine two\nLine three\nLine four")
        attachScreenshot(of: app, named: "composer-multiline")
        XCTAssertGreaterThanOrEqual(send.frame.minY, text.frame.maxY - 1, "多行時送出鈕仍在輸入框下方")
    }

    /// 注音組字(#187):組字文字跟一般文字一樣換行，輸入框跟著長高;按鈕列留在下方。
    @MainActor
    func testZhuyinCompositionWrapsAndGrowsComposer() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-AppleKeyboards", "(zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic)"])
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        app.switchKeyboard(to: .zhuyin)
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
        XCTAssertGreaterThanOrEqual(app.element("composer.send").frame.minY, text.frame.maxY - 1, "送出鈕要在輸入框下方")
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
        let text = app.element("composer.text")
        let expand = app.element("composer.expand")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        XCTAssertFalse(expand.exists, "沒聚焦、空白時不該有展開鈕")

        text.tap()
        XCTAssertTrue(expand.waitUntilExists(timeout: 5), "聚焦時沒有展開鈕")
        XCTAssertEqual(expand.label, "Expand")
        XCTAssertHitTarget(expand)
        text.typeEnglish("1\n2\n3")
        expand.tap()

        let expanded = app.element("composer.expanded.text")
        XCTAssertTrue(expanded.waitUntilExists(timeout: 5), "沒有開出展開畫面")
        XCTAssertEqual(expanded.value as? String, "1\n2\n3", "展開畫面不是同一份草稿")
        XCTAssertGreaterThan(expanded.frame.height, text.frame.height, "展開畫面的輸入框沒有比輸入列大")
        expanded.tap()
        expanded.typeEnglish("\n4")
        app.element("composer.expanded.done").tap()

        XCTAssertTrue(expanded.waitUntilGone(timeout: 5), "「完成」沒有收回")
        XCTAssertEqual(text.value as? String, "1\n2\n3\n4", "收回後草稿不見了")
        XCTAssertFalse(app.element("conversation.echo").exists, "收回不該送出")
        XCTAssertFalse(app.element("composer.hideKeyboard").exists, "收回後輸入列不該聚焦")
        XCTAssertTrue(expand.exists, "沒聚焦、4 行時應有展開鈕")
    }

    /// 在展開畫面送出(#142):回到對話、輸入列清空、有回音;鍵盤出現時送出與完成鈕在鍵盤上方。
    @MainActor
    func testSendingFromExpandedEditorReturnsToConversation() {
        let app = openLedger()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        app.element("composer.expand").tap()

        let expanded = app.element("composer.expanded.text")
        XCTAssertTrue(expanded.waitUntilExists(timeout: 5), "沒有開出展開畫面")
        expanded.tap()
        expanded.typeEnglish("Sent from the big editor")
        let send = app.element("composer.expanded.send")
        let done = app.element("composer.expanded.done")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1, "送出鈕被鍵盤擋住")
            XCTAssertLessThanOrEqual(done.frame.maxY, keyboard.frame.minY + 1, "完成鈕被鍵盤擋住")
        }
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        send.tap()

        XCTAssertTrue(expanded.waitUntilGone(timeout: 5), "送出後沒有回到對話")
        XCTAssertTrue(sentMessage("Sent from the big editor", in: app).waitUntilExists(timeout: 5), "沒有回音")
        XCTAssertEqual(text.value as? String ?? "", "", "送出後輸入框應清空")
    }

    /// AX 字級下長高不超過鍵盤上方可用高度的 40%,超過的在框內捲動(#137)。
    @MainActor
    func testComposerAtAccessibilitySizeStaysWithinAvailableHeight() {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let ledger = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(ledger), "列表沒有 ledger")
        ledger.tap()
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        text.typeEnglish("1\n2\n3\n4\n5\n6\n7\n8\n9\n10")
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
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")
        XCTAssertTrue(app.element("prompt.card").waitUntilExists(timeout: 10), "沒有提示卡")
        let jump = app.element("conversation.jumpToLatest")
        let list = app.scrollViews.firstMatch
        XCTAssertFalse(jump.waitUntilExists(timeout: 2), "在底部時不該顯示")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "往上捲後應顯示")

        for _ in 0..<4 { list.swipeUp() }
        XCTAssertTrue(jump.waitUntilGone(timeout: 5), "自己捲回底部後應隱藏")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "再往上捲應顯示")
        jump.tap()
        XCTAssertTrue(jump.waitUntilGone(timeout: 5), "點了回到最新後應隱藏")
        XCTAssertTrue(app.element("prompt.option.3").isHittable, "回到底部後最後一個選項應可點")
    }

    /// #130:往上翻看舊訊息時 agent 一次寫出超過 64 KiB(`-demoLargeOutput`:開啟 8 秒後寫出 321 行):
    /// 畫面不空白，正在看的舊訊息還在原處，新訊息接在後面。
    @MainActor
    func testLargeOutputWhileReadingKeepsMessages() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutput"])
        let first = app.staticTexts["Tidy up the CSV export: dates first, and escape commas in notes."]
        XCTAssertTrue(first.waitUntilExists(timeout: 10), "對話沒有載入完成")
        let list = app.scrollViews.firstMatch
        let jump = app.element("conversation.jumpToLatest")
        for _ in 0..<4 { list.swipeDown() }
        XCTAssertTrue(app.element("conversation.beginning").waitUntilExists(timeout: 5), "沒有翻到對話開頭")
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "往上翻後應是閱讀中")

        // 開啟後 8 秒寫出;已完成的 agent 每 4 秒輪詢一次。等寫出之後的兩次輪詢。
        Thread.sleep(forTimeInterval: 18)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-large-output-while-reading"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(first.exists && first.isHittable, "正在看的舊訊息不見了(畫面被取代或停在內容之外)")
        XCTAssertTrue(app.element("conversation.beginning").exists, "對話開頭不見了(改讀了新視窗)")
        XCTAssertTrue(jump.exists, "應仍在閱讀中")
        jump.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'I read all 160 export logs'")).firstMatch
        XCTAssertTrue(summary.waitUntilExists(timeout: 5), "新訊息沒有接在後面")
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
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        XCTAssertTrue(app.element("conversation.agent").waitUntilExists(timeout: 10), "對話沒有載入完成")

        text.tap()
        text.typeEnglish("Check the logs once more")
        app.element("composer.send").tap()
        // 軟體鍵盤＋You should know 卡片會把對話的可見範圍擠到不到一列：收起鍵盤，不依賴模擬器的鍵盤設定(#190)。
        app.dismissKeyboard()
        XCTAssertTrue(sentMessage("Check the logs once more", in: app).waitUntilExists(timeout: 5), "沒有回音")
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

    /// #210:送出後 agent 工作中、還沒回覆(`-demoWorkingAfterPrompt`,工作 15 秒)。送出的訊息與工作中指示在畫面上，
    /// 不可被一整片空白推到畫面外。
    @MainActor
    func testSendingWhileAgentWorksKeepsSentMessageVisible() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoWorkingAfterPrompt"])
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        XCTAssertTrue(app.element("conversation.agent").waitUntilExists(timeout: 10), "對話沒有載入完成")

        text.tap()
        text.typeEnglish("Add a header row too?")
        app.element("composer.send").tap()
        app.dismissKeyboard()
        XCTAssertTrue(app.element("conversation.working").waitUntilExists(timeout: 5), "沒有工作中指示")
        // 等追蹤接上使用者那一行、即時預覽出現，捲動穩定;回覆在 15 秒後才來。
        Thread.sleep(forTimeInterval: 5)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-working-after-send"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(sentMessage("Add a header row too?", in: app).isHittable, "送出的訊息應在畫面上")
        XCTAssertTrue(app.element("conversation.working").isHittable, "工作中指示應在畫面上")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'This is the demo host'")).firstMatch.exists, "回覆不該這麼早到")
    }

    /// 「需要你」的 agent 拒收：草稿放回輸入框，提示先回答。
    @MainActor
    func testBlockedAgentKeepsDraftAndExplains() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        text.typeEnglish("Go ahead")
        app.element("composer.send").tap()

        XCTAssertTrue(app.element("composer.notice").waitUntilExists(timeout: 10), "沒有提示先回答")
        XCTAssertEqual(text.value as? String, "Go ahead", "被拒時草稿應放回輸入框")
    }

    /// 對話載入中(#114):輸入列與載入完成後在同一個位置(畫面底部),轉圈仍在輸入列上方的中段。
    @MainActor
    func testComposerStaysAtBottomWhileConversationLoads() {
        // 基準：同一台模擬器上載入完成後的輸入框位置(不寫死機型幾何)。
        let loaded = openLedger()
        XCTAssertTrue(loaded.element("conversation.user").waitUntilExists(timeout: 10), "對話沒有載入完成")
        let loadedText = loaded.element("composer.text")
        XCTAssertTrue(loadedText.waitUntilExists(timeout: 5), "載入完成後沒有輸入列")
        let expected = loadedText.frame
        loaded.terminate()

        // 對話紀錄的讀取有 20 秒期限(HostCommandDeadline.standard),期限到了就離開載入中：下面的等待合計在期限內，
        // 量完再確認仍在載入中，量到的才是載入中的位置。
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoTranscriptPending"])
        let loading = app.element("conversation.loading")
        XCTAssertTrue(loading.waitUntilExists(timeout: 10), "沒有停在載入中")
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 5), "載入中沒有輸入列")
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

    /// #219:聊天時斷網(啟動 12 秒後所有主機指令立刻失敗)。頂端顯示連線中斷，畫面仍可操作：能捲動、能返回列表。
    @MainActor
    func testGoingOfflineWhileChattingKeepsAppResponsive() throws {
        try assertStaysResponsiveWhenGoingOffline(flag: "-demoGoesOffline")
    }

    /// #219:斷網時每個主機指令都卡到連線期限才失敗(像 Tailscale 不通)。畫面仍可操作。
    @MainActor
    func testGoingOfflineWithHangingConnectionsKeepsAppResponsive() throws {
        try assertStaysResponsiveWhenGoingOffline(flag: "-demoGoesOfflineHanging")
    }

    /// #219:正在打字(軟體鍵盤開著、對話可見範圍很小)時斷網，橫幅插入後畫面仍可操作。
    @MainActor
    func testGoingOfflineWhileTypingKeepsAppResponsive() throws {
        try assertStaysResponsiveWhenGoingOffline(flag: "-demoGoesOffline", typing: true)
    }

    /// #219:工作中的 agent(Codex,沒有對話紀錄;每 2 秒輪詢、讀畫面)斷網，畫面仍可操作。
    @MainActor
    func testGoingOfflineWhileAgentWorksKeepsAppResponsive() throws {
        try assertStaysResponsiveWhenGoingOffline(flag: "-demoGoesOffline", paneID: "w3:p1", hasMessages: false)
    }

    /// #219:「需要你」的 agent(提示卡占去大半畫面)斷網，畫面仍可操作。
    @MainActor
    func testGoingOfflineWhileAgentIsBlockedKeepsAppResponsive() throws {
        try assertStaysResponsiveWhenGoingOffline(flag: "-demoGoesOffline", paneID: "w2:p1")
    }

    @MainActor
    private func assertStaysResponsiveWhenGoingOffline(flag: String, paneID: String = "w1:p1", hasMessages: Bool = true, typing: Bool = false) throws {
        let app = XCUIApplication.launchUITestingConversation(paneID: paneID, flags: [flag])
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "聊天畫面沒有開啟")
        let message = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["conversation.user", "conversation.agent", "conversation.toolRun"])).firstMatch
        XCTAssertTrue(!hasMessages || message.waitUntilExists(timeout: 10), "對話沒有載入完成")
        if typing {
            let text = app.element("composer.text")
            text.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitUntilExists(timeout: 5), "鍵盤沒有叫出來")
            guard keyboard.frame.height > 150 else { throw XCTSkip("模擬器接著硬體鍵盤，沒有軟體鍵盤") }
            text.typeEnglish("Typing while the network drops")
        }
        let offline = app.staticTexts["Offline — showing the last loaded conversation."]
        XCTAssertTrue(offline.waitUntilExists(timeout: 60), "斷網後沒有顯示連線中斷橫幅")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "conversation-offline"
        shot.lifetime = .keepAlways
        add(shot)

        if typing { app.dismissKeyboard() }
        if hasMessages {
            let list = app.scrollViews.firstMatch
            list.swipeDown()
            list.swipeUp()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 10), "斷網後點返回沒有回到列表")
    }

    /// 等元素的 accessibility value 以指定文字開頭(縮放有動畫)。
    @MainActor
    private func waitForValue(of element: XCUIElement, beginning prefix: String, timeout: TimeInterval = 3) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String, value.hasPrefix(prefix) { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.value as? String
    }
}
