import XCTest

/// 變更頁(#310):Demo 主機 ledger 的 git 變更清單 → 單檔 diff,在行上寫評論後送給 Agent。
final class ChangesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openChanges(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["spaces.tab.demo/w1:t1"].firstMatch
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        app.conversationMoreItem("changes.open").tap()
    }

    @MainActor
    func testCommentOnLineAndSendToAgent() {
        let app = XCUIApplication.launchUITesting()
        openChanges(app)
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
        field.typeText("Count carriage returns too")
        XCTAssertTrue(save.wait(for: NSPredicate(format: "isEnabled == true"), timeout: 5), "有內容後 ✓ 應可按")
        save.tap()

        XCTAssertTrue(app.descendants(matching: .any)["changes.comment.5"].firstMatch.waitUntilExists(timeout: 5), "評論卡片沒有出現")
        let send = app.buttons["changes.review.send"].firstMatch
        XCTAssertTrue(send.waitUntilExists(timeout: 5), "沒有送出評論鈕")
        send.tap()

        // 回到聊天，評論組成的訊息出現在對話裡。
        let echo = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Count carriage returns too")).firstMatch
        XCTAssertTrue(echo.waitUntilExists(timeout: 10), "評論沒有送到聊天")
        XCTAssertTrue(app.buttons["conversation.more"].firstMatch.waitUntilExists(timeout: 5), "沒有回到聊天")
    }

}
