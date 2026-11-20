import XCTest

/// 新增對話(#272,原型 purrdr-screens 定案版:主機、Agent、資料夾、第一則訊息),走 Demo 主機：資料夾瀏覽在同一個 sheet 內 push,
/// Demo 拒絕開始並說明。
final class NewChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openNewChat() -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        app.openMoreMenuItem("menu.newChat")
        XCTAssertTrue(app.textFields["newChat.folder"].waitForExistence(timeout: 5), "沒有開出新增對話")
        return app
    }

    /// 瀏覽 Demo 家目錄 → ledger → 空的 reports(說明沒有子資料夾，不是錯誤)→ 上一層 → 再進去 → 使用這個資料夾 → 回到表單並填好。
    @MainActor
    func testChooseFolderOnHostFillsForm() {
        let app = openNewChat()
        let start = app.buttons["newChat.start"]
        XCTAssertFalse(start.isEnabled, "資料夾空白時不能開始")
        let message = app.textViews["newChat.message"].exists ? app.textViews["newChat.message"] : app.textFields["newChat.message"]
        message.tap()
        message.typeEnglish("Fix the CSV quoting")

        app.buttons["newChat.chooseFolder"].tap()
        let ledger = app.buttons["folderPicker.row.ledger"]
        XCTAssertTrue(ledger.waitForExistence(timeout: 10), "資料夾瀏覽沒有列出家目錄的 ledger")
        XCTAssertTrue(app.buttons["folderPicker.row.notes"].exists)
        // 同一個 sheet 內 push:表單的 Cancel 已被推走，左上是返回。
        XCTAssertFalse(app.buttons["newChat.cancel"].exists, "資料夾瀏覽應該 push 在同一個 sheet 內")

        ledger.tap()
        let reports = app.buttons["folderPicker.row.reports"]
        XCTAssertTrue(reports.waitForExistence(timeout: 5))
        reports.tap()
        XCTAssertTrue(app.descendants(matching: .any)["folderPicker.empty"].firstMatch.waitForExistence(timeout: 5), "空資料夾沒有說明")
        XCTAssertFalse(app.descendants(matching: .any)["folderPicker.error"].firstMatch.exists, "空資料夾不是錯誤")

        // 比照檔案頁：點麵包屑的上一段回到 ledger(沒有「上一層」按鈕)。
        XCTAssertFalse(app.buttons["folderPicker.up"].exists)
        app.buttons["folderPicker.crumb.1"].tap()
        XCTAssertTrue(app.buttons["folderPicker.row.reports"].waitForExistence(timeout: 5), "點麵包屑沒有回到 ledger")
        app.buttons["folderPicker.row.reports"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["folderPicker.empty"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["folderPicker.use"].tap()

        let folder = app.textFields["newChat.folder"]
        XCTAssertTrue(app.buttons["newChat.cancel"].waitForExistence(timeout: 5), "沒有回到表單")
        XCTAssertEqual(folder.value as? String, "/Users/demo/ledger/reports")
        XCTAssertTrue(start.isEnabled)
    }

    /// 表單只有 Agent(分段控制)、資料夾、第一則訊息與「開始」,沒有名稱與權限欄位;資料夾與訊息都填才能開始。
    /// Demo 主機拒絕開始，錯誤顯示在表單裡、sheet 不關。
    @MainActor
    func testFormFieldsAndDemoRejection() {
        let app = openNewChat()
        XCTAssertTrue(app.segmentedControls["newChat.agent"].exists, "Agent 不是分段控制")
        XCTAssertFalse(app.textFields["newChat.name"].exists, "不該有名稱欄位")
        XCTAssertFalse(app.buttons["newChat.permissionMode"].exists, "不該有權限欄位")

        let start = app.buttons["newChat.start"]
        let folder = app.textFields["newChat.folder"]
        folder.tap()
        folder.typeEnglish("~/ledger")
        XCTAssertFalse(start.isEnabled, "沒有第一則訊息不能開始")
        let message = app.textViews["newChat.message"].exists ? app.textViews["newChat.message"] : app.textFields["newChat.message"]
        message.tap()
        message.typeEnglish("Fix the CSV quoting")
        XCTAssertTrue(start.isEnabled)
        start.tap()

        let error = app.descendants(matching: .any)["newChat.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), "Demo 拒絕時沒有說明")
        XCTAssertTrue(error.label.contains("Demo"), "說明沒有提到 Demo:\(error.label)")
        XCTAssertTrue(app.buttons["newChat.cancel"].exists, "失敗時 sheet 不該關閉")
    }
}
