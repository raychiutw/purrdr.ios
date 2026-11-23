import XCTest

/// 對話標題列資訊、重新載入、停止列與強制結束(#44、#220)、工作中指示。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
final class ConversationHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 標題列(#270、#380):標題是 workspace 名稱，下一行是狀態與主機名(context 百分比在狀態 sheet);右邊只有終端機鈕，
    /// 沒有重新載入(改成下拉重新整理)。不在工作中沒有停止列。
    @MainActor
    func testHeaderShowsWorkspaceStatusAndHost() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10))

        XCTAssertTrue(app.navigationBars.staticTexts["ledger"].firstMatch.exists, "標題不是 workspace 名稱")
        let header = app.element("conversation.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 5), "標題下沒有資訊行")
        XCTAssertEqual(header.label, "Done, Demo", "資訊行應只有狀態與主機名(context、待辦在狀態 sheet，#349、#380)")
        XCTAssertFalse(app.element("conversation.reload").exists, "標題列不該再有重新載入")
        XCTAssertFalse(app.element("stopBar").exists, "不在工作中不該有停止列")

        // 下拉重新整理：重讀後對話仍在。
        let list = app.scrollViews.firstMatch
        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10), "下拉重新整理後沒有重讀對話")
    }

    /// 工作中(#220):輸入卡片最上面有停止列，送出鈕照舊。
    /// 點停止送 Esc:停止中按鈕念「Stopping…」且停用，停下後顯示「Stopped」,約 2 秒後停止列收起、工作中指示消失。
    @MainActor
    func testWorkingAgentStopsFromStopBar() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")

        let working = app.element("conversation.working")
        XCTAssertTrue(working.waitUntilExists(timeout: 10), "工作中沒有指示")
        XCTAssertTrue(app.element("conversation.header").label.hasPrefix("Working"))
        XCTAssertFalse(app.element("conversation.stop").exists, "標題列不該再有停止")
        XCTAssertTrue(app.element("composer.send").exists, "送出鈕應該維持原樣")

        let stop = app.element("stopBar.stop")
        XCTAssertTrue(stop.waitUntilExists(timeout: 5), "工作中沒有停止列的停止鈕")
        XCTAssertEqual(stop.label, "Stop Codex")
        stop.tap()

        let stopping = app.element("stopBar.stopping")
        // 停止中不到 1 秒，waitForExistence 第一次檢查就要等約 1 秒：直接查。
        XCTAssertTrue(stopping.exists, "按下後沒有顯示停止中")
        XCTAssertFalse(stopping.isEnabled, "停止中應該停用")

        let result = app.element("stopBar.result")
        XCTAssertTrue(result.waitUntilExists(timeout: 10), "停下後沒有顯示結果")
        XCTAssertTrue(result.label.contains("Stopped"), "結果應該是已停止：\(result.label)")
        XCTAssertTrue(app.element("stopBar").waitUntilGone(timeout: 6), "已停止沒有自動收起")
        XCTAssertTrue(working.waitUntilGone(timeout: 5), "停下後指示沒有消失")
    }

    /// 長按停止鈕開出選單，「Force Quit…」要先在確認對話框確認才送 Ctrl-C。
    @MainActor
    func testForceQuitFromLongPressNeedsConfirmation() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")
        let stop = app.element("stopBar.stop")
        XCTAssertTrue(stop.waitUntilExists(timeout: 10))

        stop.press(forDuration: 1.0)
        let menuItem = app.buttons["Force Quit…"]
        XCTAssertTrue(menuItem.waitUntilExists(timeout: 5), "長按沒有強制結束的選項")
        menuItem.tap()

        let confirm = app.buttons["stopBar.forceQuit.confirm"].firstMatch
        XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "強制結束沒有先確認")
        XCTAssertTrue(app.staticTexts["Force Quit Codex?"].exists, "確認對話框標題不對")
        confirm.tap()

        XCTAssertTrue(app.element("conversation.working").waitUntilGone(timeout: 15), "強制結束後仍在工作")
        XCTAssertTrue(app.element("stopBar").waitUntilGone(timeout: 10), "強制結束後停止列還在")
    }

    /// 「需要你」的 agent 永不中斷：沒有停止列。
    @MainActor
    func testNeedsYouAgentHasNoStopBar() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")
        XCTAssertTrue(app.element("conversation.header").waitUntilExists(timeout: 10))
        XCTAssertTrue(app.element("conversation.header").label.hasPrefix("Needs"), "應該是需要你")
        XCTAssertFalse(app.element("stopBar").exists, "需要你不該有停止列")
    }
}
