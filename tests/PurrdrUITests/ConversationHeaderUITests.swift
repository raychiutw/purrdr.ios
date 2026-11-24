import XCTest

/// 對話標題列資訊、重新載入、停止列與強制結束(#44、#220)、工作中指示。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
final class ConversationHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 標題列(#270、#514):第一行 Tab 名稱，第二行主機名與狀態(context 百分比在用量 sheet);右邊只有終端機鈕，
    /// 沒有重新載入(改成下拉重新整理)。不在工作中沒有停止列。
    @MainActor
    func testHeaderShowsWorkspaceStatusAndHost() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10))

        let header = app.element("conversation.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 5), "沒有標題膠囊")
        // 兩行膠囊(#514):Tab 名稱、主機、狀態、權限模式都在 VoiceOver 標籤裡。
        XCTAssertTrue(header.label.contains("Done"), "標籤沒有狀態:\(header.label)")
        XCTAssertTrue(header.label.contains("Demo"), "標籤沒有主機名:\(header.label)")
        XCTAssertFalse(app.element("conversation.reload").exists, "標題列不該再有重新載入")
        XCTAssertFalse(app.element("stopBar").exists, "不在工作中不該有停止列")

        // 下拉重新整理：重讀後對話仍在。
        let list = app.conversationList
        list.swipeDown()
        list.swipeDown()
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10), "下拉重新整理後沒有重讀對話")
    }

    /// 其他聊天需要你(#529):開 ledger(w1:p1)時,Demo 的 weather-app(w2:p1)正等著,系統返回鈕右上疊小點、VoiceOver 念出數量;
    /// 返回仍是系統返回鈕(點得到、邊緣滑動可用)。
    @MainActor
    func testBackButtonShowsDotWhenOtherChatNeedsYou() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 10))

        let dot = app.element("conversation.needsYouDot")
        XCTAssertTrue(dot.waitUntilExists(timeout: 10), "其他聊天需要你時返回鈕沒有小點")
        XCTAssertTrue(dot.label.contains("1"), "標籤沒有帶數量:\(dot.label)")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.frame.insetBy(dx: -8, dy: -8).intersects(dot.frame), "小點不在返回鈕上:\(dot.frame) vs \(back.frame)")

        // 邊緣滑動返回仍可用。
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.withOffset(CGVector(dx: 2, dy: 0)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 5), "邊緣滑動沒有返回列表")
    }

    /// 工作中(#220):輸入卡片最上面有停止列，送出鈕照舊。
    /// 點停止送 Esc:停止中按鈕念「Stopping…」且停用，停下後顯示「Stopped」,約 2 秒後停止列收起、工作中指示消失。
    @MainActor
    func testWorkingAgentStopsFromStopBar() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")

        let working = app.element("conversation.working")
        XCTAssertTrue(working.waitUntilExists(timeout: 10), "工作中沒有指示")
        XCTAssertTrue(app.element("conversation.header").label.contains("Working"))
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
        XCTAssertTrue(app.element("conversation.header").label.contains("Needs"), "應該是需要你")
        XCTAssertFalse(app.element("stopBar").exists, "需要你不該有停止列")
    }

    /// 用量環(#513):點開用量 sheet(Context 與方案用量區塊),X 關閉。
    @MainActor
    func testUsageRingOpensUsageSheet() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 15), "沒有用量環")

        ring.tap()

        XCTAssertTrue(app.element("usage.sheet").waitUntilExists(timeout: 5), "點用量環沒有開出用量 sheet")
        XCTAssertTrue(app.element("usage.sheet.refresh").exists, "沒有重新整理")
        app.buttons["usage.sheet.close"].tap()
        XCTAssertTrue(app.element("usage.sheet").waitUntilGone(timeout: 5), "X 之後用量 sheet 還在")
    }
}
