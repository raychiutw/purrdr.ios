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

    // MARK: - 已送出圖片情境(`-demoSentImages`,#428:手機沒有副本，經主機讀回縮圖)

    /// 使用者送出的三張圖：兩張經主機取檔讀回縮圖、可點開圖片檢視器;一張已被主機清掉，顯示「主機上已找不到」。
    @MainActor
    func testSentImagesReadBackFromHost() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoSentImages"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitUntilExists(timeout: 10), "對話沒有開啟")
        let thumbnail = app.element("conversation.sentImage.thumbnail")
        XCTAssertTrue(app.revealInConversation(thumbnail), "已送出的圖片沒有經主機讀回縮圖")
        XCTAssertTrue(
            app.element("conversation.sentImage.note").waitUntilExists(timeout: 10), "被主機清掉的圖片沒有說明")
        thumbnail.tap()
        // 圖片檢視器(#426):同一則訊息還在主機的兩張圖(被清掉的那張不進清單);頁數、左右切換、分享、下滑關閉。
        XCTAssertTrue(app.element("imageViewer").waitUntilExists(timeout: 5), "點縮圖沒有開圖片檢視器")
        XCTAssertEqual(app.element("imageViewer.pageLabel").label, "Image 1 of 2")
        XCTAssertTrue(app.element("imageViewer.share").waitUntilExists(timeout: 10), "讀到圖後沒有分享鈕")
        let image = app.element("imageViewer.image")
        XCTAssertTrue(image.waitUntilExists(timeout: 5))
        image.swipeLeft()
        let second = NSPredicate(format: "label == %@", "Image 2 of 2")
        let moved = XCTNSPredicateExpectation(predicate: second, object: app.element("imageViewer.pageLabel"))
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "左滑沒有切到第 2 張")
        image.swipeRight()
        let first = NSPredicate(format: "label == %@", "Image 1 of 2")
        let back = XCTNSPredicateExpectation(predicate: first, object: app.element("imageViewer.pageLabel"))
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 5), .completed, "右滑沒有回到第 1 張")
        app.element("imageViewer.image").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.element("imageViewer").waitUntilGone(timeout: 5), "下滑沒有關閉圖片檢視器")
    }

    /// 使用者送出的兩份檔案(#429):一份經主機讀回縮小檔案卡片(大小、點開以 QuickLook),一份已被主機清掉顯示說明。
    @MainActor
    func testSentFilesShowCards() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoSentImages"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitUntilExists(timeout: 10), "對話沒有開啟")
        let size = app.element("conversation.userFile.size")
        XCTAssertTrue(app.revealInConversation(size), "使用者送出的檔案沒有顯示大小")
        XCTAssertTrue(app.element("conversation.userFile.note").waitUntilExists(timeout: 10), "被主機清掉的檔案沒有說明")
        app.buttons["conversation.userFile"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitUntilExists(timeout: 10), "點檔案卡片沒有以 QuickLook 開啟")
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
        let header = "conversation.agentFile.row"
        for prefix in ["Created file draft.csv", "Created file history.csv"] {
            XCTAssertTrue(app.revealInConversation(app.element(header, labelPrefix: prefix)), "沒有 \(prefix) 的卡片")
        }
        let created = app.element(header, labelPrefix: "Created file CSVQuotingTests.swift, Code")
        XCTAssertTrue(app.revealInConversation(created), "新建卡片標題不對")
        let edited = app.element(header, labelPrefix: "Edited file CSVExport.swift, Code")
        XCTAssertTrue(app.revealInConversation(edited), "修改卡片標題不對")
        XCTAssertTrue(edited.label.contains("1 lines added, 1 removed"), "\(edited.label)")
        XCTAssertFalse(edited.label.contains("Path:"), "路徑是進階資訊，收合時標題不念：\(edited.label)")

        // #465:卡片是緊湊單列,路徑與內容(修改摘要)在長按選單的「Details」sheet。
        XCTAssertFalse(app.staticTexts["/Users/demo/ledger/Sources/Ledger/CSVExport.swift"].exists, "路徑不該顯示在卡片上")
        XCTAssertFalse(app.element("conversation.agentFile.content").exists, "內容不該顯示在卡片上")
        created.press(forDuration: 1.0)
        let details = app.buttons["Details"].firstMatch
        XCTAssertTrue(details.waitUntilExists(timeout: 5), "長按沒有「Details」")
        details.tap()
        XCTAssertTrue(app.element("conversation.agentFile.path").waitUntilExists(timeout: 5), "詳細沒有路徑")
        XCTAssertTrue(app.element("conversation.agentFile.content").waitUntilExists(timeout: 5), "詳細沒有內容")
        let lastLine = app.staticTexts[#"    #expect(CSVExport.columns.first == "date")"#]
        XCTAssertTrue(lastLine.waitUntilExists(timeout: 5), "詳細沒有完整內容(含最後一行)")
        app.element("conversation.agentFile.details.close").tap()
        XCTAssertTrue(app.element("conversation.agentFile.details").waitUntilGone(timeout: 5))

        // 圖片卡片:小圖自動載入縮圖，點開全螢幕;超過 8 MiB 的掃描檔等點擊。
        let previewHeader = app.element("conversation.agentImage.header", labelPrefix: "Read file export-preview.png, Image")
        XCTAssertTrue(app.revealInConversation(previewHeader), "沒有預覽圖的圖片卡片")
        let thumbnail = app.element("conversation.agentImage.thumbnail", labelPrefix: "Image export-preview.png")
        XCTAssertTrue(thumbnail.waitUntilExists(timeout: 15), "預覽圖沒有自動載入縮圖")
        XCTAssertTrue(app.revealInConversation(thumbnail))
        XCTAssertFalse(app.staticTexts["docs/export-preview.png"].exists)
        thumbnail.tap()
        XCTAssertTrue(app.element("imageViewer").waitUntilExists(timeout: 5), "沒有全螢幕檢視")
        XCTAssertGreaterThanOrEqual(app.element("imageViewer.close").frame.height, 44)

        // #330:雙點兩下放大、再雙點兩下縮回;1× 下滑關閉。
        let image = app.element("imageViewer.image")
        XCTAssertEqual(image.value as? String, "Not zoomed")
        image.doubleTap()
        let zoomed = waitForValue(of: image, beginning: "Zoomed in")
        XCTAssertTrue(zoomed?.hasPrefix("Zoomed in") == true, "雙點兩下沒有放大：\(String(describing: zoomed))")
        image.doubleTap()
        _ = waitForValue(of: image, beginning: "Not zoomed")
        XCTAssertEqual(image.value as? String, "Not zoomed", "再雙點兩下沒有縮回")
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.element("imageViewer").waitUntilGone(timeout: 5), "1× 下滑沒有關閉")

        XCTAssertTrue(app.revealInConversation(thumbnail))
        thumbnail.tap()
        XCTAssertTrue(app.element("imageViewer.close").waitUntilExists(timeout: 5))
        app.element("imageViewer.close").tap()
        XCTAssertTrue(app.element("imageViewer").waitUntilGone(timeout: 5))

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

        // 點開檔案:點整列下載後以 QuickLook 預覽,關閉後長按選單可以分享。
        XCTAssertTrue(app.revealInConversation(created), "新建的測試檔沒有卡片")
        XCTAssertGreaterThanOrEqual(created.frame.height, 44)
        created.tap()
        let preview = quickLookBar(named: "CSVQuotingTests", in: app)
        XCTAssertTrue(preview.waitUntilExists(timeout: 15), "沒有出現 QuickLook 預覽")
        closeQuickLook(preview)
        XCTAssertTrue(preview.waitUntilGone(timeout: 5))

        // 檔案縮圖(#427、#465):PDF 卡片左側自動載入第一頁縮圖,點整列以 QuickLook 開。
        let pdfRow = app.element("conversation.agentFile.row", labelPrefix: "Created file export-report.pdf")
        XCTAssertTrue(app.revealInConversation(pdfRow), "沒有 PDF 卡片")
        pdfRow.tap()
        let pdfBar = quickLookBar(named: "export-report", in: app)
        XCTAssertTrue(pdfBar.waitUntilExists(timeout: 15), "點整列沒有出現 QuickLook 預覽")
        closeQuickLook(pdfBar)
        XCTAssertTrue(pdfBar.waitUntilGone(timeout: 5))

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
        XCTAssertTrue(app.element("imageViewer").waitUntilExists(timeout: 10), "點了圖片路徑沒有全螢幕檢視")
        app.element("imageViewer.close").tap()
        XCTAssertTrue(app.element("imageViewer").waitUntilGone(timeout: 5))

        // 下載好的檔案:長按選單可以分享(放最後,免得還要收起選單)。
        XCTAssertTrue(app.revealInConversation(created))
        created.press(forDuration: 1.0)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Share")).firstMatch.waitUntilExists(timeout: 5), "下載好之後長按沒有「Share」")

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
    /// 兩態(收合一列、展開兩列與模型膠囊,#382)、沒有收起鍵盤鈕與展開鈕、收起鍵盤保留草稿(#37)、
    /// 點訊息區與往下拖曳收起鍵盤(#329)、長高到 5 行後框內捲動(#382)。
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

        // 收合(#382):一列 +、輸入、送出;沒有模型膠囊、收鍵盤鈕、展開鈕。
        let addImage = app.element("composer.attach")
        XCTAssertTrue(addImage.exists, "沒有加入圖片鈕")
        XCTAssertFalse(send.isEnabled, "空白時送出鈕應停用")
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertGreaterThanOrEqual(addImage.frame.height, 44)
        XCTAssertLessThan(addImage.frame.maxX, text.frame.minX + 1, "收合時加入圖片在輸入框左邊")
        XCTAssertLessThan(text.frame.maxX, send.frame.minX + 1, "收合時送出在輸入框右邊")
        XCTAssertEqual(text.frame.midY, send.frame.midY, accuracy: 4, "收合時輸入與送出同一列")
        XCTAssertGreaterThanOrEqual(text.frame.height, 44, "空白時低於 44pt(\(text.frame.height)pt)")
        XCTAssertFalse(app.element("composer.model").exists, "收合時不該有模型膠囊")
        XCTAssertFalse(app.element("composer.hideKeyboard").exists, "輸入列不該有收起鍵盤鈕")
        XCTAssertFalse(app.element("composer.expand").exists, "輸入列不該有展開鈕")
        XCTAssertFalse(app.element("composer.permissionMode").exists, "輸入列不該有權限模式鈕")

        // 聚焦展開:上方輸入、下方 +、模型膠囊、送出;打字後至少兩行高;收起後草稿還在、沒有送出。
        text.tap()
        let capsule = app.element("composer.model")
        XCTAssertTrue(capsule.waitUntilExists(timeout: 5), "聚焦展開後沒有模型膠囊")
        XCTAssertGreaterThanOrEqual(send.frame.minY, text.frame.maxY - 1, "展開時送出鈕要在輸入框下方")
        XCTAssertGreaterThanOrEqual(addImage.frame.minY, text.frame.maxY - 1, "展開時加入圖片鈕要在輸入框下方")
        XCTAssertGreaterThan(capsule.frame.minX, addImage.frame.maxX - 1, "模型膠囊在加入圖片右邊")
        XCTAssertLessThan(capsule.frame.maxX, send.frame.minX, "模型膠囊不壓到送出")
        XCTAssertEqual(capsule.frame.midY, addImage.frame.midY, accuracy: 2, "模型膠囊與加入圖片同一列")
        let capsuleText = capsule.value as? String ?? ""
        XCTAssertFalse(capsuleText.isEmpty || capsuleText.hasSuffix("…"), "模型膠囊被截斷:\(capsuleText)")
        XCTAssertFalse(app.element("composer.hideKeyboard").exists, "聚焦時也沒有收起鍵盤鈕")
        text.typeEnglish("Line one")
        XCTAssertGreaterThanOrEqual(text.frame.height, 60, "有內容時不到兩行高(\(text.frame.height)pt)")
        app.dismissKeyboard()
        XCTAssertEqual(text.value as? String, "Line one", "草稿不見了")
        XCTAssertTrue(app.element("composer.model").exists, "有草稿時收起鍵盤仍是展開")
        XCTAssertFalse(app.element("conversation.echo").exists, "收起鍵盤不該送出")

        // 點訊息區收起鍵盤。
        text.tap()
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "點訊息區後鍵盤沒有收起")

        // 往下拖曳聊天收起鍵盤。
        text.tap()
        XCTAssertTrue(app.waitForKeyboard(), "鍵盤沒有叫出來")
        let screen = app.windows.firstMatch
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(
            forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "拖曳後鍵盤沒有收起")
        clearDraft(text)

        // 長高到 5 行為止,超過在框內捲動(#382)。
        text.typeEnglish("1\n2")
        let twoLines = text.frame.height
        text.typeEnglish("\n3")
        let lineHeight = text.frame.height - twoLines
        XCTAssertGreaterThan(lineHeight, 10, "第 3 行沒有長高")
        text.typeEnglish("\n4\n5\n6\n7\n8")
        // 上限同時受鍵盤上方可用高度的 40% 限制(#137):收起鍵盤再量，不依賴模擬器接的是軟體還是實體鍵盤(#190)。
        app.dismissKeyboard()
        let capped = text.frame.height
        XCTAssertGreaterThan(capped, twoLines + lineHeight * 2.5, "5 行沒有攤開(\(capped)pt,2 行 \(twoLines)、行高 \(lineHeight))")
        XCTAssertLessThan(capped, twoLines + lineHeight * 3.5, "超過 5 行應在框內捲動而不是繼續長高(\(capped)pt)")
        XCTAssertEqual(text.value as? String, "1\n2\n3\n4\n5\n6\n7\n8", "草稿不完整")
    }

    /// 送出(單一啟動,原本 3 個測試合併,#374):輸入框清空、回音出現，agent 收下後對話紀錄接上回覆、回音消失;
    /// 送出後立刻收起鍵盤(#329)。
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
        // 「需要你」改成浮動卡(#424)後對話列表本身不夠長，改用長對話。
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        XCTAssertTrue(app.scrollViews.firstMatch.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")
        let list = app.scrollViews.firstMatch
        XCTAssertFalse(jump.waitUntilExists(timeout: 2), "在底部時不該顯示")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "往上捲後應顯示")
        // 在輸入列(含停止列)上方,不被它蓋住(#476)。
        let composer = app.element("composer.text")
        XCTAssertLessThanOrEqual(jump.frame.maxY, composer.frame.minY, "跳到最新壓在輸入列上")

        for _ in 0..<4 { list.swipeUp() }
        XCTAssertTrue(jump.waitUntilGone(timeout: 5), "自己捲回底部後應隱藏")

        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(jump.waitUntilExists(timeout: 5), "再往上捲應顯示")
        jump.tap()
        XCTAssertTrue(jump.waitUntilGone(timeout: 5), "點了回到最新後應隱藏")
    }

    /// #401:往上滑後(含手指剛放開、畫面還在減速時)點「Jump to Latest」,真的回到最底(最後一則在輸入框之上)、按鈕不再冒出來。
    @MainActor
    func testJumpToLatestReturnsToBottomEvenWhileDecelerating() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoLargeOutputOnPrompt"])
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "對話沒有開啟")
        let jump = app.element("conversation.jumpToLatest")
        let composer = app.element("composer.text")
        XCTAssertTrue(composer.waitUntilExists(timeout: 5))

        for attempt in 1...3 {
            // 用力快滑幾次:放開後仍在減速時立刻點。
            for _ in 0..<3 { list.swipeDown(velocity: .fast) }
            XCTAssertTrue(jump.waitUntilExists(timeout: 5), "第 \(attempt) 次往上捲後應顯示")
            jump.tap()
            let lastUser = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question 150:'")).firstMatch
            XCTAssertTrue(lastUser.waitUntilExists(timeout: 5), "第 \(attempt) 次點了之後最後一則沒有出現在畫面上")
            XCTAssertTrue(jump.waitUntilGone(timeout: 5), "第 \(attempt) 次點了之後按鈕沒有消失")
            // 之後也不能又冒出來(被拉回閱讀中)。
            XCTAssertFalse(jump.waitUntilExists(timeout: 2), "第 \(attempt) 次點了之後按鈕又出現(沒有真的到底)")
            XCTAssertLessThanOrEqual(lastUser.frame.maxY, composer.frame.minY + 1, "第 \(attempt) 次最後一則被輸入框蓋住")
        }
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
