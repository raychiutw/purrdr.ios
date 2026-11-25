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
    func testChangeListShowsBranchAndFiles() {
        let app = XCUIApplication.launchUITesting()
        openChanges(app)

        let summary = app.descendants(matching: .any)["changes.summary"].firstMatch
        XCTAssertTrue(summary.waitUntilExists(timeout: 10), "沒有變更清單")
        XCTAssertTrue(summary.label.contains("master"), "分支不對:\(summary.label)")
        for path in ["Fixtures/draft.csv", "Sources/CSVExport.swift", "Tests/CSVQuotingTests.swift"] {
            XCTAssertTrue(app.buttons["changes.file.\(path)"].firstMatch.exists, "沒有 \(path)")
        }
        let csv = app.buttons["changes.file.Sources/CSVExport.swift"].firstMatch
        XCTAssertTrue(csv.label.contains("3 added, 1 removed"), "+/− 不對:\(csv.label)")
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
        line.tap()
        let field = app.textFields["changes.comment.field"].firstMatch
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "沒有評論輸入框")
        app.assertModalToolbar(close: "sheet.close", confirm: "changes.comment.save")
        XCTAssertFalse(app.buttons["changes.comment.save"].firstMatch.isEnabled, "沒有內容時 ✓ 應停用")
        field.typeText("Count carriage returns too")
        XCTAssertTrue(app.buttons["changes.comment.save"].firstMatch.isEnabled, "有內容後 ✓ 應可按")
        app.buttons["changes.comment.save"].firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any)["changes.comment.5"].firstMatch.waitUntilExists(timeout: 5), "評論卡片沒有出現")
        let send = app.buttons["changes.review.send"].firstMatch
        XCTAssertTrue(send.waitUntilExists(timeout: 5), "沒有送出評論鈕")
        send.tap()

        // 回到聊天，評論組成的訊息出現在對話裡。
        let echo = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Count carriage returns too")).firstMatch
        XCTAssertTrue(echo.waitUntilExists(timeout: 10), "評論沒有送到聊天")
        XCTAssertTrue(app.buttons["conversation.more"].firstMatch.waitUntilExists(timeout: 5), "沒有回到聊天")
    }

    /// 更多選單(#381):資料夾不是 Git repo 時，「Git 變更」停用並寫原因;其他兩項照常。
    @MainActor
    func testGitItemDisabledOutsideRepository() {
        let app = XCUIApplication.launchUITesting()
        app.openConversation(paneID: "w2:p1")
        let git = app.conversationMoreItem("changes.open")
        XCTAssertTrue(UITestWait.until(timeout: 10) { !git.isEnabled }, "不在 Git 資料夾卻沒有停用")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pane Terminal")).firstMatch.isEnabled, "終端機項目不該停用")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show Layout")).firstMatch.exists, "更多選單沒有顯示版面")
    }
}
