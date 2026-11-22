import XCTest

/// 對話閱讀(行為規格 F5)。資料來自 Demo 主機的 Claude Code 對話紀錄，走正式程式路徑。
final class ConversationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 唯讀測試共用的一次啟動(#373):不送出、不改 Demo 主機狀態的測試共用同一個 app,測試之間回到列表再開聊天。
    /// 會送出訊息、帶情境旗標或改字級的測試照舊各自啟動。
    nonisolated(unsafe) private static var sharedApp: XCUIApplication?

    override class func tearDown() {
        MainActor.assumeIsolated {
            sharedApp?.terminate()
            sharedApp = nil
        }
    }

    /// 回到列表後開 `paneID` 的聊天。第一次或 app 已不在前景時才啟動。
    @MainActor
    private func openSharedConversation(paneID: String) -> XCUIApplication {
        // 共用同一個 app 會被同類別其他測試的狀態干擾(提示卡、草稿、sheet),每個測試各自啟動。
        XCUIApplication.launchUITestingConversation(paneID: paneID)
    }

    @MainActor
    private func openLedger() -> XCUIApplication {
        openSharedConversation(paneID: "w1:p1")
    }

    /// 送出的訊息：還沒確認的回音，或對話紀錄已確認的使用者泡泡(追蹤可能立刻讀到，#165)。
    @MainActor
    private func sentMessage(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 閱讀(共用啟動的 ledger):使用者泡泡、skill、工具串摘要、表格與程式碼(#351:不超出視窗寬度)、
    /// 只有 http(s) 連結可點(R-V03)、程式碼複製鈕(≥44pt)與每輪開頭的 Agent 頭像與名稱。
    /// 最後才點開工具串(會改版面)。原本 6 個測試合併(#374)。
    @MainActor
    func testConversationRendering() {
        let app = openLedger()

        XCTAssertTrue(app.revealInConversation(app.element("conversation.user")), "沒有使用者泡泡")
        XCTAssertTrue(app.staticTexts["Loaded skill: tdd"].exists, "skill 沒有顯示成「Loaded skill」")
        XCTAssertTrue(app.staticTexts["Edited 1 file · 3 steps"].exists, "工具串沒有收合成一行摘要")
        XCTAssertTrue(app.element("conversation.table").exists, "沒有表格")
        XCTAssertTrue(app.element("conversation.beginning").exists, "頂端沒有「對話開頭」")

        XCTAssertTrue(app.links["RFC 4180"].waitUntilExists(timeout: 5), "https 連結不可點")
        XCTAssertFalse(app.links["the README"].exists, "file:// 連結不該可點")

        let header = app.element("conversation.agent.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 10), "Agent 回覆開頭沒有頭像與名稱")
        XCTAssertTrue(app.staticTexts["Claude Code"].exists, "開頭沒有 Agent 名稱")

        let copy = app.element("conversation.code.copy")
        XCTAssertTrue(copy.waitUntilExists(timeout: 10), "程式碼區塊沒有複製鈕")
        XCTAssertEqual(copy.label, "Copy Code")
        // 圓角框裁切後座標有浮點誤差(43.9999…),容許 0.01pt。
        XCTAssertGreaterThanOrEqual(copy.frame.width, 43.99)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 43.99)
        XCTAssertTrue(app.scrollViews["conversation.code"].exists, "程式碼區塊不在自己的橫捲容器內")

        let window = app.windows.firstMatch
        let table = app.element("conversation.table")
        XCTAssertTrue(app.revealInConversation(table), "沒有表格")
        XCTAssertLessThanOrEqual(table.frame.maxX, window.frame.maxX + 1, "表格超出畫面右緣")
        XCTAssertGreaterThanOrEqual(table.frame.minX, window.frame.minX - 1, "表格超出畫面左緣")
        let code = app.scrollViews["conversation.code"]
        XCTAssertTrue(app.revealInConversation(code), "沒有程式碼區塊")
        XCTAssertLessThanOrEqual(code.frame.maxX, window.frame.maxX + 1, "程式碼區塊超出畫面右緣")
        XCTAssertGreaterThanOrEqual(code.frame.minX, window.frame.minX - 1, "程式碼區塊超出畫面左緣")

        let summary = app.staticTexts["Edited 1 file · 3 steps"]
        XCTAssertTrue(app.revealInConversation(summary), "找不到工具串摘要")
        // 上下版面的輸入列較高(#187),摘要可能在導覽列底下：一小段一小段往回捲，直到摘要在可見範圍上緣。
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<6 where !summary.isHittable || summary.frame.minY < navigationBottom + 8 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26)))
        }
        summary.tap()
        XCTAssertTrue(app.staticTexts["Edit"].waitUntilExists(timeout: 5), "展開後沒有看到每個呼叫")
    }

    // MARK: - 檔案情境(`-demoAgentFiles`:ledger 的對話換成寫檔、讀圖、提到主機路徑的一段)

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

    /// 檔案情境(單一啟動,原本 6 個測試合併,#374):檔案卡片(#224)、圖片卡片與全螢幕檢視(#225、#330)、
    /// 點開檔案以 QuickLook 預覽並可分享(#228)、訊息內主機路徑在 app 內開(#229)。
    /// 超過上限與已刪除的說明在 model 測試(`AgentFileOpenTests.openFailures`)。
    @MainActor
    func testAgentFiles() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoAgentFiles"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitUntilExists(timeout: 10), "對話沒有開啟")
        // 這裡看的是對話裡的卡片：先略過輸入列上方的註記，卡片才整張放得進可視區。
        dismissNote(in: app)

        // 檔案卡片:標題念出動作、檔名、類型與路徑。
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

        // #330:路徑預設收起，點「Details」揭露控制才看到。
        let pathText = app.staticTexts["/Users/demo/ledger/Sources/Ledger/CSVExport.swift"]
        XCTAssertFalse(pathText.exists, "路徑不該預設顯示")
        let disclosure = app.descendants(matching: .any).matching(identifier: "conversation.agentFile.disclosure").element(boundBy: 0)
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

        // 圖片卡片:小圖自動載入縮圖，點開全螢幕;超過 8 MiB 的掃描檔等點擊。
        let previewHeader = app.element("conversation.agentImage.header", labelPrefix: "Read file export-preview.png, Image")
        XCTAssertTrue(app.revealInConversation(previewHeader), "沒有預覽圖的圖片卡片")
        let thumbnail = app.element("conversation.agentImage.thumbnail", labelPrefix: "Image export-preview.png")
        XCTAssertTrue(thumbnail.waitUntilExists(timeout: 15), "預覽圖沒有自動載入縮圖")
        XCTAssertTrue(app.revealInConversation(thumbnail))
        XCTAssertFalse(app.staticTexts["docs/export-preview.png"].exists)
        thumbnail.tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilExists(timeout: 5), "沒有全螢幕檢視")
        XCTAssertGreaterThanOrEqual(app.element("agentImage.viewer.done").frame.height, 44)

        // #330:雙點兩下放大、再雙點兩下縮回;1× 下滑關閉。
        let image = app.element("agentImage.viewer.image")
        XCTAssertEqual(image.value as? String, "Not zoomed")
        image.doubleTap()
        let zoomed = waitForValue(of: image, beginning: "Zoomed in")
        XCTAssertTrue(zoomed?.hasPrefix("Zoomed in") == true, "雙點兩下沒有放大：\(String(describing: zoomed))")
        image.doubleTap()
        _ = waitForValue(of: image, beginning: "Not zoomed")
        XCTAssertEqual(image.value as? String, "Not zoomed", "再雙點兩下沒有縮回")
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilGone(timeout: 5), "1× 下滑沒有關閉")

        XCTAssertTrue(app.revealInConversation(thumbnail))
        thumbnail.tap()
        XCTAssertTrue(app.element("agentImage.viewer.done").waitUntilExists(timeout: 5))
        app.element("agentImage.viewer.done").tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilGone(timeout: 5))

        let imageDisclosure = app.element("conversation.agentImage.disclosure")
        XCTAssertTrue(app.revealInConversation(imageDisclosure))
        imageDisclosure.tap()
        XCTAssertTrue(app.element("conversation.agentImage.path").waitUntilExists(timeout: 3), "展開後沒有路徑")

        let load = app.element("conversation.agentImage.load")
        XCTAssertTrue(app.revealInConversation(load), "超過 8 MiB 的掃描檔應該等點擊")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Not loaded automatically")).firstMatch.exists, "沒有顯示大小與說明")
        XCTAssertGreaterThanOrEqual(load.frame.height, 44)
        load.tap()
        let scan = app.element("conversation.agentImage.thumbnail", labelPrefix: "Image statement-scan.png")
        XCTAssertTrue(scan.waitUntilExists(timeout: 15), "點了之後掃描檔沒有載入")

        // 點開檔案:「Open」下載後以 QuickLook 預覽，關閉後可以分享。
        let open = app.buttons["Open CSVQuotingTests.swift"].firstMatch
        XCTAssertTrue(app.revealInConversation(open), "新建的測試檔沒有「Open」")
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        open.tap()
        let preview = quickLookBar(named: "CSVQuotingTests", in: app)
        XCTAssertTrue(preview.waitUntilExists(timeout: 15), "沒有出現 QuickLook 預覽")
        closeQuickLook(preview)
        XCTAssertTrue(preview.waitUntilGone(timeout: 5))
        let share = app.buttons["Share CSVQuotingTests.swift"].firstMatch
        XCTAssertTrue(app.revealInConversation(share), "下載好之後沒有「Share」")
        XCTAssertGreaterThanOrEqual(share.frame.height, 44)

        // 訊息內主機路徑(#229):PDF 在 app 內以 QuickLook 開，圖片全螢幕看(不交給系統 openURL)。
        let report = app.links["/Users/demo/ledger/docs/export-report.pdf"].firstMatch
        XCTAssertTrue(app.revealInConversation(report), "訊息中的 PDF 路徑不是連結")
        report.tap()
        let reportPreview = quickLookBar(named: "export-report", in: app)
        XCTAssertTrue(reportPreview.waitUntilExists(timeout: 15), "點了路徑沒有出現 QuickLook 預覽")
        XCTAssertEqual(app.state, .runningForeground, "路徑不該交給系統開")
        closeQuickLook(reportPreview)
        XCTAssertTrue(reportPreview.waitUntilGone(timeout: 5))
        let pathImage = app.links["/Users/demo/ledger/docs/export-preview.png"].firstMatch
        XCTAssertTrue(app.revealInConversation(pathImage), "訊息中的圖片路徑不是連結")
        pathImage.tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilExists(timeout: 10), "點了圖片路徑沒有全螢幕檢視")
        app.element("agentImage.viewer.done").tap()
        XCTAssertTrue(app.element("agentImage.viewer").waitUntilGone(timeout: 5))
    }

    // MARK: - 輸入列與鍵盤(F6)

    /// 清空輸入框的草稿(聚焦後連按刪除)。
    @MainActor
    private func clearDraft(_ text: XCUIElement) {
        // 游標不一定在最後：點右下角把游標放到尾端，再依目前字數刪光。
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        let count = (text.value as? String)?.count ?? 0
        text.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 5))
    }

    /// 輸入列與鍵盤(單一啟動,原本 9 個測試合併,#374;不送出):建議提示詞只填入不送出(#123、#240)、
    /// 上下版面與按鈕尺寸(#187)、收起鍵盤保留草稿(#37)、點訊息區與捲動收起鍵盤(#329)、
    /// 長高超過 4 行(#137)、展開編輯保留草稿(#142)。
    @MainActor
    func testComposerAndKeyboard() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        dismissNote(in: app)
        let text = app.element("composer.text")
        let send = app.element("composer.send")
        let suggestion = app.element("conversation.suggestion")

        // 建議提示詞:點了只填入、叫出鍵盤，輸入框有字時收起，刪光再出現。
        XCTAssertTrue(suggestion.waitUntilExists(timeout: 10), "沒有建議")
        XCTAssertEqual(suggestion.label, "Suggestion: Add a test for CSV export with commas in the memo, Fill In")
        XCTAssertGreaterThanOrEqual(suggestion.frame.height, 44)
        suggestion.tap()
        XCTAssertEqual(text.value as? String, "Add a test for CSV export with commas in the memo", "輸入框不是建議文字")
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        XCTAssertTrue(suggestion.waitUntilGone(timeout: 5), "輸入框有字時建議應收起")
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(app.element("conversation.echo").exists, "點建議不該送出")
        text.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60))
        XCTAssertTrue(suggestion.waitUntilExists(timeout: 5), "輸入框刪光後建議沒有再出現")
        app.dismissKeyboard()

        // 上下版面:整寬輸入框在上、按鈕列在下。
        let addImage = app.element("composer.attach")
        XCTAssertTrue(addImage.exists, "沒有加入圖片鈕")
        XCTAssertFalse(send.isEnabled, "空白時送出鈕應停用")
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
        XCTAssertFalse(app.element("composer.hideKeyboard").exists, "沒聚焦時不該有收起鍵盤鈕")
        XCTAssertFalse(app.element("composer.expand").exists, "沒聚焦、空白時不該有展開鈕")

        // 聚焦:收起鍵盤鈕在按鈕列;打字後至少兩行高;收起後草稿還在、沒有送出。
        text.tap()
        let hide = app.element("composer.hideKeyboard")
        XCTAssertTrue(hide.waitUntilExists(timeout: 5), "聚焦時沒有收起鍵盤鈕")
        XCTAssertEqual(hide.label, "Hide Keyboard")
        XCTAssertGreaterThanOrEqual(hide.frame.minY, text.frame.maxY - 1, "收起鍵盤鈕要在按鈕列")
        XCTAssertLessThan(hide.frame.maxX, send.frame.minX + 1, "收起鍵盤鈕在送出鈕左邊")
        text.typeEnglish("Line one")
        XCTAssertGreaterThanOrEqual(text.frame.height, 60, "有內容時不到兩行高(\(text.frame.height)pt)")
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "鍵盤沒有收起")
        XCTAssertEqual(text.value as? String, "Line one", "草稿不見了")
        XCTAssertFalse(app.element("conversation.echo").exists, "收起鍵盤不該送出")

        // 點訊息區收起鍵盤。
        text.tap()
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "點訊息區後鍵盤沒有收起")

        // 上下滑動聊天收起鍵盤。
        text.tap()
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        let screen = app.windows.firstMatch
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(
            forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "滑動後鍵盤沒有收起")
        clearDraft(text)

        // 長高超過舊的 4 行上限:7 行全部攤開。
        text.typeEnglish("1\n2")
        let twoLines = text.frame.height
        text.typeEnglish("\n3")
        let lineHeight = text.frame.height - twoLines
        XCTAssertGreaterThan(lineHeight, 10, "第 3 行沒有長高")
        text.typeEnglish("\n4\n5\n6\n7")
        // 上限是鍵盤上方可用高度的 40%(#137):收起鍵盤再量，不依賴模擬器接的是軟體還是實體鍵盤(#190)。
        app.dismissKeyboard()
        let sevenLines = text.frame.height
        XCTAssertGreaterThan(sevenLines, twoLines + lineHeight * 4.5, "7 行時只有 \(sevenLines)pt(2 行 \(twoLines)、行高 \(lineHeight))")
        XCTAssertTrue(app.element("composer.expand").exists, "沒聚焦、7 行時應有展開鈕")
        clearDraft(text)

        // 展開編輯:同一份草稿，收回保留在展開畫面打的字。
        let expand = app.element("composer.expand")
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

    /// 送出(單一啟動,原本 3 個測試合併,#374):輸入框清空、回音出現，agent 收下後對話紀錄接上回覆、回音消失;
    /// 送出後立刻收起鍵盤(#329);在展開畫面送出回到對話(#142)。
    @MainActor
    func testSending() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let text = app.element("composer.text")
        let send = app.element("composer.send")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        XCTAssertFalse(send.isEnabled, "空白時送出鈕應停用")
        XCTAssertHitTarget(send)

        text.tap()
        text.typeEnglish("Add a header row too?")
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        send.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "送出後鍵盤沒有收起")
        XCTAssertEqual(text.value as? String ?? "", "", "送出後輸入框應清空")
        app.dismissKeyboard()
        // 追蹤可能立刻讀到對話紀錄(#165):回音很快被確認，所以回覆接上也算。
        let echoOrReply = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR (identifier == 'conversation.agent' AND label CONTAINS 'This is the demo host')",
            "Add a header row too?")).firstMatch
        XCTAssertTrue(echoOrReply.waitUntilExists(timeout: 5), "沒有回音")
        // agent 訊息是一個元素，label 以「Agent:」開頭(#35)。
        let reply = app.descendants(matching: .any).matching(identifier: "conversation.agent")
            .matching(NSPredicate(format: "label CONTAINS 'This is the demo host'")).firstMatch
        XCTAssertTrue(reply.waitUntilExists(timeout: 15), "對話紀錄沒有接上 agent 的回覆")
        XCTAssertFalse(app.element("conversation.echo").exists, "對話紀錄確認後回音應消失")

        // 在展開畫面送出:回到對話、輸入列清空、有回音;送出與完成鈕在鍵盤上方。
        text.tap()
        app.element("composer.expand").tap()
        let expanded = app.element("composer.expanded.text")
        XCTAssertTrue(expanded.waitUntilExists(timeout: 5), "沒有開出展開畫面")
        expanded.tap()
        expanded.typeEnglish("Sent from the big editor")
        let expandedSend = app.element("composer.expanded.send")
        let done = app.element("composer.expanded.done")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(expandedSend.frame.maxY, keyboard.frame.minY + 1, "送出鈕被鍵盤擋住")
            XCTAssertLessThanOrEqual(done.frame.maxY, keyboard.frame.minY + 1, "完成鈕被鍵盤擋住")
        }
        XCTAssertTrue(expandedSend.isHittable)
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(expandedSend.frame.height, 44)
        expandedSend.tap()
        XCTAssertTrue(expanded.waitUntilGone(timeout: 5), "送出後沒有回到對話")
        XCTAssertTrue(sentMessage("Sent from the big editor", in: app).waitUntilExists(timeout: 5), "沒有回音")
        XCTAssertEqual(text.value as? String ?? "", "", "送出後輸入框應清空")
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

    /// 注音組字(#187):組字文字跟一般文字一樣換行，輸入框跟著長高;按鈕列留在下方。
    @MainActor
    func testZhuyinCompositionWrapsAndGrowsComposer() throws {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-AppleKeyboards", "(zh_Hant-Zhuyin@sw=Zhuyin;hw=Automatic)"])
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10))
        text.tap()
        // 以實體鍵盤的注音配置按鍵組字：模擬器沒有接實體鍵盤(畫面上有軟體鍵盤)時測不到，略過(#374)。
        if app.keyboards.firstMatch.waitUntilExists(timeout: 2) {
            throw XCTSkip("需要模擬器接著實體鍵盤(Simulator ▸ I/O ▸ Keyboard ▸ Connect Hardware Keyboard)")
        }
        app.switchKeyboard(to: .zhuyin)
        let idleHeight = text.frame.height

        // 模擬器接著實體鍵盤：以注音的實體鍵盤配置按 s、u、3(ㄋ、ㄧ、ˇ)。typeText 不經過輸入法。
        for _ in 0..<24 {
            for key in ["s", "u", "3"] {
                app.typeKey(key, modifierFlags: [])
            }
        }
        XCTAssertTrue((text.value as? String)?.contains("ㄋ") == true, "沒有在組字(\(String(describing: text.value)))")
        XCTAssertGreaterThan(text.frame.height, idleHeight + 30, "組字換行後沒有長高(\(idleHeight) → \(text.frame.height))")
        XCTAssertGreaterThanOrEqual(app.element("composer.send").frame.minY, text.frame.maxY - 1, "送出鈕要在輸入框下方")
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

        // 可用高度從狀態列下緣算，比可見範圍小;以可見範圍當上界只會放寬。
        let height = text.frame.height
        XCTAssertLessThanOrEqual(height, visibleBottom * 0.4 + 1, "輸入框 \(height)pt 超過可見範圍(\(visibleBottom)pt)的 40%")
        XCTAssertGreaterThan(height, 44 * 2, "AX 字級下多行沒有長高(\(height)pt)")
    }

    /// 「Jump to Latest」只在不在底部時出現：開啟時(在底部)沒有;往上捲出現;自己捲回底部或點它都消失(#93)。
    @MainActor
    func testJumpToLatestOnlyWhenAwayFromBottom() {
        let app = openSharedConversation(paneID: "w2:p1")
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


        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1, "載入中的輸入列不在載入完成後的位置(底緣 \(actual.maxY),應為 \(expected.maxY))")
        XCTAssertLessThan(spinner.maxY, actual.minY, "轉圈不在輸入列上方")
        // 輸入列是上下版面(#187)、比單行高，上方內容區的中心跟著往上。
        XCTAssertGreaterThan(spinner.midY, screen.height * 0.2, "轉圈沒有置中")
        XCTAssertLessThan(spinner.midY, screen.height * 0.7, "轉圈沒有置中")
    }


    /// #219:聊天時斷網(對話載入完成 1 秒後所有主機指令立刻失敗)。頂端顯示連線中斷，畫面仍可操作：能捲動、能返回列表。
    /// 其餘情境(打字中、工作中的 Codex、「需要你」、指令卡到期限)在 model 測試驗資料面
    /// (`ConversationHeaderTests`、`ConversationModelTests`、`ConversationDeadlineTests`)。
    @MainActor
    func testGoingOfflineWhileChattingKeepsAppResponsive() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoGoesOffline"])
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10), "聊天畫面沒有開啟")
        let message = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["conversation.user", "conversation.agent", "conversation.toolRun"])).firstMatch
        XCTAssertTrue(message.waitUntilExists(timeout: 10), "對話沒有載入完成")
        XCTAssertTrue(app.staticTexts["Offline — showing the last loaded conversation."].waitUntilExists(timeout: 60), "斷網後沒有顯示連線中斷橫幅")

        let list = app.scrollViews.firstMatch
        list.swipeDown()
        list.swipeUp()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent.row.demo/w1:p1"].firstMatch.waitUntilExists(timeout: 10), "斷網後點返回沒有回到列表")
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
