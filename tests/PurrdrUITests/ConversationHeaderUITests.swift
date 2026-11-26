import XCTest

/// 對話標題列資訊、重新載入、停止列與強制結束(#44、#220)、工作中指示。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
final class ConversationHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 工作中(#220):輸入卡片最上面有停止列，送出鈕照舊。
    /// 點停止送 Esc:停止中按鈕念「Stopping…」且停用，停下後顯示「Stopped」,約 2 秒後停止列收起、工作中指示消失。
    @MainActor
    func testWorkingAgentStopsFromStopBar() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")

        let working = app.element("conversation.working")
        XCTAssertTrue(working.waitUntilExists(timeout: 10), "工作中沒有指示")
        XCTAssertTrue(app.conversationSubtitle(containing: "Working").waitUntilExists(timeout: 5), "副標題沒有工作中")
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

    /// 頂列右上只有用量環與「⋯」(#617):沒有 Inspector 開關鈕,兩顆並排(系統合成一顆膠囊)。
    @MainActor
    func testHeaderTrailingHasOnlyRingAndMore() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let ring = app.buttons["conversation.usage"].firstMatch
        let more = app.buttons["conversation.more"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 15), "沒有用量環")
        XCTAssertTrue(more.exists, "沒有「⋯」")
        XCTAssertFalse(app.buttons["conversation.inspectorToggle"].exists, "不該有 Inspector 開關鈕")
        XCTAssertLessThanOrEqual(ring.frame.maxX, more.frame.minX + 1, "用量環應該在「⋯」左邊並排")
        // 同一個 ToolbarItemGroup 由系統合成一顆膠囊:兩顆同高、垂直置中對齊,間距是膠囊內的間距(不是兩個獨立工具列項目的距離)。
        // XCUITest 看不到合成後的玻璃形狀,以 frame 關係佐證。
        XCTAssertEqual(ring.frame.midY, more.frame.midY, accuracy: 2, "用量環與「⋯」垂直沒有對齊")
        XCTAssertEqual(ring.frame.height, more.frame.height, accuracy: 4, "用量環與「⋯」不同高")
        XCTAssertLessThanOrEqual(more.frame.minX - ring.frame.maxX, 24, "用量環與「⋯」間距太大,不像同一顆膠囊")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.frame.maxX < ring.frame.minX {
            XCTAssertGreaterThan(ring.frame.minX - back.frame.maxX, more.frame.minX - ring.frame.maxX, "用量環離返回鈕比離「⋯」還近")
        }
    }
}
