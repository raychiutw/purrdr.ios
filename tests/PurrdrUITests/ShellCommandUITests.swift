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
    func testShellBlockThenSecretCheckThenSendWhenDoneReason() {
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
    }
}
