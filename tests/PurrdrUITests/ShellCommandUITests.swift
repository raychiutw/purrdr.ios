import XCTest

/// Shell `!` 指令(行為規格 F5.9、F6.4;#43)。只對 Demo 主機送出，走正式程式路徑。
final class ShellCommandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 打 `!` 開頭時輸入列上方有提示;送出後出現終端機風格的區塊，長按可複製輸出或指令。
    /// 接著機密偵測(#302):送出像含有密鑰的訊息時底部升起說明 sheet(類別與行號，不顯示內容),
    /// 「返回編輯」放回輸入框,「仍要送出」照常送出;最後「⋯」→ 做完再送(#626):不能用的原因寫在開關下方，不跳 alert。
    @MainActor
    func testShellBlockSecretCheckSendWhenDoneReasonThenChangesComment() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()

        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        text.tap()
        text.typeEnglish("hello")
        XCTAssertFalse(app.element("composer.shellHint").exists, "一般草稿不該有 shell 提示")
        text.clearAndType("!ls Sources")
        XCTAssertTrue(app.element("composer.shellHint").waitUntilExists(timeout: 5), "沒有 shell 模式提示")

        app.element("composer.send").tap()

        let block = app.element("conversation.shell")
        XCTAssertTrue(block.waitUntilExists(timeout: 15), "對話紀錄沒有接上 shell 區塊")
        XCTAssertTrue(app.staticTexts["$ ls Sources"].waitUntilExists(timeout: 5), "沒有 `$ 指令`")
        let stdout = app.element("conversation.shell.stdout")
        XCTAssertTrue(stdout.waitUntilExists(timeout: 5), "沒有輸出")
        XCTAssertTrue((stdout.label).hasPrefix("demo: this is the demo host"))
        XCTAssertEqual(app.element("conversation.shell.status").label, "2 lines of output")
        XCTAssertTrue(app.element("conversation.echo").waitUntilGone(timeout: 5), "shell 區塊出現後回音應消失")
        XCTAssertTrue(app.element("composer.shellHint").waitUntilGone(timeout: 5), "送出後草稿清空，提示應消失")

        block.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Copy Output"].waitUntilExists(timeout: 5), "長按沒有「Copy Output」")
        let copyCommand = app.buttons["Copy Command"]
        XCTAssertTrue(copyCommand.exists, "長按沒有「Copy Command」")
        copyCommand.tap()
        XCTAssertTrue(copyCommand.waitUntilGone(timeout: 5), "選單沒有收起")

        // 機密偵測
        let send = app.element("composer.send")
        let message = "Deploy with DB_PASSWORD=hunter2024"
        text.tap()
        text.typeEnglish(message)
        send.tap()

        let sheet = app.element("secretCheck.sheet")
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "沒有跳出機密偵測的說明")
        let finding = app.element("secretCheck.finding.password")
        XCTAssertTrue(finding.exists, "沒有列出偵測到的類別")
        XCTAssertTrue(finding.label.contains("Line 1"), "沒有說明在第幾行：\(finding.label)")
        XCTAssertFalse(sheet.label.contains("hunter2024"), "說明不應顯示內容本身")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'hunter2024'")).firstMatch.exists,
                       "說明不應顯示內容本身")

        app.assertModalToolbar(close: "secretCheck.close")
        app.buttons["secretCheck.close"].tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "左上 X 應等於返回編輯")
        text.expectValue(message)
        send.tap()
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5))
        app.element("secretCheck.backToEditing").tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "返回編輯後 sheet 應關閉")
        text.expectValue(message)

        send.tap()
        XCTAssertTrue(sheet.waitUntilExists(timeout: 5), "再送一次應再確認")
        app.element("secretCheck.sendAnyway").tap()
        XCTAssertTrue(sheet.waitUntilGone(timeout: 5), "仍要送出後 sheet 應關閉")
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(sent.waitUntilExists(timeout: 10), "仍要送出後應送出這則訊息")
        XCTAssertNotEqual(text.value as? String, message, "送出後輸入框應清空")

        // 做完再送:SSH(Demo)主機沒有主機服務,原因寫在開關下方。
        app.conversationMoreItem("menu.sendWhenDone").tap()
        let toggle = app.element("status.sendWhenDone")
        XCTAssertTrue(toggle.waitUntilExists(timeout: 10), "做完再送 sheet 沒有開關")
        let reason = app.element("status.sendWhenDone.reason")
        XCTAssertTrue(reason.waitUntilExists(timeout: 10), "沒有寫在開關下方的原因")
        XCTAssertTrue(reason.label.contains("host service"), reason.label)
        toggle.tap()
        XCTAssertFalse(app.alerts.firstMatch.waitUntilExists(timeout: 2), "點停用的開關不該跳 alert")
        XCTAssertNotEqual(toggle.value as? String, "On", "停用的開關不該開啟")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(toggle.waitUntilGone(timeout: 5), "做完再送 sheet 沒有關閉")

        // 變更頁(#310;原 ChangesUITests):git 變更清單 → 單檔 diff,在行上寫評論後送給 Agent。
        app.conversationMoreItem("changes.open").tap()
        let file = app.buttons["changes.file.Sources/CSVExport.swift"].firstMatch
        XCTAssertTrue(file.waitUntilExists(timeout: 10))
        file.tap()

        let diff = app.descendants(matching: .any)["changes.diff"].firstMatch
        XCTAssertTrue(diff.waitUntilExists(timeout: 10), "沒有打開 diff")
        let line = app.descendants(matching: .any)["changes.line.5"].firstMatch
        XCTAssertTrue(line.waitUntilExists(timeout: 10), "沒有 diff 的行")
        XCTAssertTrue(line.waitUntilHittable(timeout: 5), "diff 的行不能點")
        line.tap()
        let field = app.textFields["changes.comment.field"].firstMatch
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "沒有評論輸入框")
        app.assertModalToolbar(close: "sheet.close", confirm: "changes.comment.save")
        let save = app.buttons["changes.comment.save"].firstMatch
        XCTAssertFalse(save.isEnabled, "沒有內容時 ✓ 應停用")
        // sheet 剛出現時欄位的第一下輸入可能還沒有焦點:以焦點為準再打字。
        XCTAssertTrue(app.focusTextField(field), "評論輸入框沒有取得焦點")
        field.typeEnglish("Count carriage returns too")
        XCTAssertTrue(save.wait(for: NSPredicate(format: "isEnabled == true"), timeout: 5), "有內容後 ✓ 應可按")
        save.tap()

        XCTAssertTrue(app.descendants(matching: .any)["changes.comment.5"].firstMatch.waitUntilExists(timeout: 5), "評論卡片沒有出現")
        let sendReview = app.buttons["changes.review.send"].firstMatch
        XCTAssertTrue(sendReview.waitUntilExists(timeout: 5), "沒有送出評論鈕")
        sendReview.tap()

        // 回到聊天，評論組成的訊息出現在對話裡。
        let echo = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Count carriage returns too")).firstMatch
        XCTAssertTrue(echo.waitUntilExists(timeout: 10), "評論沒有送到聊天")
        XCTAssertTrue(app.buttons["conversation.more"].firstMatch.waitUntilExists(timeout: 5), "沒有回到聊天")
    }
}
