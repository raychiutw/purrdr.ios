import XCTest

/// 新增對話(#272,原型 purrdr-screens 定案版:主機、Agent、資料夾、第一則訊息),走 Demo 主機：新增聊天是 push(#621),
/// 資料夾瀏覽每往下一層也是 push,Demo 拒絕開始並說明。
final class NewChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openNewChat() -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        app.openNewChat()
        // 資料夾欄在列表下方(lazy,不在 accessibility tree),先往上捲才看得到。
        let sheet = app.element("newChat.page")
        XCTAssertTrue(sheet.waitUntilExists(timeout: 10), "沒有開出新增對話")
        // 第一個欄位多了「放在哪裡」(#537):資料夾欄更靠下,往上拉到看得到為止。
        for _ in 0..<4 where !app.textFields["newChat.folder"].exists { sheet.swipeUp() }
        XCTAssertTrue(app.textFields["newChat.folder"].waitUntilExists(timeout: 5), "新增對話沒有資料夾欄")
        return app
    }

    /// 瀏覽 Demo 家目錄 → ledger → 空的 reports(說明沒有子資料夾，不是錯誤)→ 上一層 → 再進去 → 使用這個資料夾 → 回到表單並填好。
    @MainActor
    func testChooseFolderOnHostFillsForm() {
        let app = openNewChat()
        let start = app.buttons["newChat.start"]
        app.scrollIntoView(start, search: .down)
        XCTAssertFalse(start.isEnabled, "資料夾空白時不能開始")
        let message = app.textViews["newChat.message"].exists ? app.textViews["newChat.message"] : app.textFields["newChat.message"]
        message.tap()
        message.typeEnglish("Fix the CSV quoting")

        app.buttons["newChat.chooseFolder"].tap()
        let ledger = app.buttons["folderPicker.row.ledger"]
        XCTAssertTrue(ledger.waitUntilExists(timeout: 10), "資料夾瀏覽沒有列出家目錄的 ledger")
        XCTAssertTrue(app.buttons["folderPicker.row.notes"].exists)
        // 資料夾瀏覽是 push:表單被推走,左上是系統返回。
        XCTAssertFalse(app.textFields["newChat.folder"].exists, "資料夾瀏覽應該 push 在表單上")
        XCTAssertFalse(app.buttons["newChat.back"].exists, "資料夾瀏覽左上是系統返回,不是表單的確認返回")

        ledger.tap()
        let reports = app.buttons["folderPicker.row.reports"]
        XCTAssertTrue(reports.waitUntilExists(timeout: 5))
        reports.tap()
        XCTAssertTrue(app.descendants(matching: .any)["folderPicker.empty"].firstMatch.waitUntilExists(timeout: 5), "空資料夾沒有說明")
        XCTAssertFalse(app.descendants(matching: .any)["folderPicker.error"].firstMatch.exists, "空資料夾不是錯誤")

        // 比照檔案頁：點麵包屑的上一段回到 ledger(沒有「上一層」按鈕)。
        XCTAssertFalse(app.buttons["folderPicker.up"].exists)
        app.buttons["folderPicker.crumb.1"].tap()
        XCTAssertTrue(app.buttons["folderPicker.row.reports"].waitUntilExists(timeout: 5), "點麵包屑沒有回到 ledger")
        // 系統返回也回到上一層(ledger → 家目錄 → ledger)。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["folderPicker.row.ledger"].waitUntilExists(timeout: 5), "左上返回沒有回到家目錄")
        ledger.tap()
        XCTAssertTrue(app.buttons["folderPicker.row.reports"].waitUntilExists(timeout: 5))
        app.buttons["folderPicker.row.reports"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["folderPicker.empty"].firstMatch.waitUntilExists(timeout: 5))
        app.buttons["folderPicker.use"].tap()

        let folder = app.textFields["newChat.folder"]
        XCTAssertTrue(app.element("newChat.page").waitUntilExists(timeout: 10), "沒有回到表單")
        for _ in 0..<4 where !folder.exists { app.swipeUp() }
        XCTAssertTrue(folder.waitUntilExists(timeout: 5), "表單沒有資料夾欄")
        XCTAssertEqual(folder.value as? String, "/Users/demo/ledger/reports")
        // 回到表單後列表停在上方,「開始」在下面(lazy,不在 accessibility tree):先捲到看得到。
        app.scrollIntoView(start, search: .down)
        XCTAssertTrue(start.waitUntilExists(timeout: 5), "表單沒有「開始」")
        XCTAssertTrue(start.isEnabled)
    }

    /// 既有 Workspace(#537):第一個欄位選 ledger 後資料夾欄消失(沿用它的資料夾)、Workspace 名稱欄消失;
    /// 填第一則訊息開始 → Demo 在 ledger 新增 Tab 並啟動 agent,sheet 關閉,新 Tab 的 Agent 出現在列表。
    @MainActor
    func testStartInExistingWorkspaceAddsATab() {
        let app = XCUIApplication.launchUITesting()
        app.openNewChat()
        let sheet = app.element("newChat.page")
        XCTAssertTrue(sheet.waitUntilExists(timeout: 10), "沒有開出新增對話")
        // 選項是勾選列(#313 同做法),以標籤找:Workspace 名稱加資料夾。
        let ledger = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ledger'")).firstMatch
        XCTAssertTrue(ledger.waitUntilExists(timeout: 10), "沒有列出既有的 Workspace ledger")
        XCTAssertTrue(app.buttons["New Workspace"].exists, "沒有「新的 Workspace」")
        ledger.tap()

        XCTAssertTrue(app.descendants(matching: .any)["newChat.placement.footer"].firstMatch.waitUntilExists(timeout: 5), "選了既有 Workspace 沒有說明")
        sheet.swipeUp()
        XCTAssertFalse(app.textFields["newChat.folder"].exists, "選了既有 Workspace 不需要資料夾")
        XCTAssertFalse(app.textFields["newChat.workspaceName"].exists, "既有 Workspace 沒有 Workspace 名稱欄")
        let tabName = app.textFields["newChat.tabName"]
        app.scrollIntoView(tabName, search: .down)
        XCTAssertTrue(tabName.waitForExistence(timeout: 5), "既有 Workspace 沒有 Tab 名稱欄")

        let message = app.textViews["newChat.message"].exists ? app.textViews["newChat.message"] : app.textFields["newChat.message"]
        message.tap()
        message.typeEnglish("Add a second tab")
        let start = app.buttons["newChat.start"]
        app.scrollIntoView(start, search: .down)
        XCTAssertTrue(start.isEnabled)
        start.tap()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "開始後新增聊天沒有收掉")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.reveal(app.descendants(matching: .any)[chatRowID("w1:p2")].firstMatch), "新 Tab 的 Agent 沒有出現在列表")
    }

    /// 表單只有 Agent(攤開的勾選列,#313)、資料夾、選填的 Workspace／Tab 名稱(#532)、第一則訊息與「開始」,沒有權限欄位;資料夾與訊息都填才能開始。
    /// Demo 主機拒絕開始，錯誤顯示在表單裡、sheet 不關。
    @MainActor
    func testFormFieldsAndDemoRejection() {
        let app = openNewChat()
        XCTAssertFalse(app.segmentedControls["newChat.agent"].exists, "Agent 不該是分段控制(#313 攤開)")
        // Agent 在「放在哪裡」下面:列表是 lazy,先捲到看得到。
        for _ in 0..<4 where !app.buttons["Claude Code"].exists { app.swipeDown() }
        XCTAssertTrue(app.buttons["Claude Code"].exists && app.buttons["Codex"].exists, "Agent 選項沒有攤開")
        // 名稱兩欄選填(#532):沒填也能開始,下面開始時兩欄都空。
        let workspaceName = app.textFields["newChat.workspaceName"]
        app.scrollIntoView(workspaceName, search: .down)
        XCTAssertTrue(workspaceName.waitForExistence(timeout: 5), "沒有 Workspace 名稱欄位")
        XCTAssertTrue(app.textFields["newChat.tabName"].exists, "沒有 Tab 名稱欄位")
        XCTAssertFalse(app.buttons["newChat.permissionMode"].exists, "不該有權限欄位")

        let start = app.buttons["newChat.start"]
        let folder = app.textFields["newChat.folder"]
        folder.tap()
        folder.typeEnglish("~/ledger")
        // 名稱欄位多了一段,「開始」在畫面外時表單還沒排出它:往下捲到出現。
        for _ in 0..<4 where !start.exists { app.swipeUp() }
        XCTAssertFalse(start.isEnabled, "沒有第一則訊息不能開始")
        let message = app.textViews["newChat.message"].exists ? app.textViews["newChat.message"] : app.textFields["newChat.message"]
        message.tap()
        message.typeEnglish("Fix the CSV quoting")
        XCTAssertTrue(start.isEnabled)
        start.tap()

        let error = app.descendants(matching: .any)["newChat.error"].firstMatch
        XCTAssertTrue(error.waitUntilExists(timeout: 10), "Demo 拒絕時沒有說明")
        XCTAssertTrue(error.label.contains("Demo"), "說明沒有提到 Demo:\(error.label)")
        XCTAssertTrue(app.element("newChat.page").exists, "失敗時新增聊天不該離開")
    }
}
