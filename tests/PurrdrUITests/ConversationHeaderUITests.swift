import XCTest

/// 對話標題列資訊、重新載入、停止列與強制結束(#44、#220)、工作中指示。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
final class ConversationHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func open(paneID: String) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 標題下一行有狀態與 agent 名稱(VoiceOver 念完整內容);標題列是「重新載入」,點了重讀對話。不在工作中沒有停止列。
    @MainActor
    func testHeaderShowsInfoAndReloadRereads() {
        let app = open(paneID: "w1:p1")
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10))

        let header = element("conversation.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 5), "標題下沒有資訊行")
        XCTAssertTrue(header.label.hasPrefix("Done"), "資訊行沒有狀態字：\(header.label)")
        XCTAssertTrue(header.label.contains("Claude Code"), "資訊行沒有 agent 名稱：\(header.label)")
        XCTAssertFalse(element("stopBar", in: app).exists, "不在工作中不該有停止列")

        let reload = element("conversation.reload", in: app)
        XCTAssertTrue(reload.exists, "沒有重新載入")
        XCTAssertEqual(reload.label, "Reload")
        reload.tap()
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10), "重新載入後沒有重讀對話")
    }

    /// 工作中(#220):輸入卡片最上面有停止列，送出鈕照舊，標題列仍是「重新載入」。
    /// 點停止送 Esc:停止中按鈕念「Stopping…」且停用，停下後顯示「Stopped」,約 2 秒後停止列收起、工作中指示消失。
    @MainActor
    func testWorkingAgentStopsFromStopBar() {
        let app = open(paneID: "w3:p1")

        let working = element("conversation.working", in: app)
        XCTAssertTrue(working.waitForExistence(timeout: 10), "工作中沒有指示")
        XCTAssertTrue(element("conversation.header", in: app).label.hasPrefix("Working"))
        XCTAssertTrue(element("conversation.reload", in: app).exists, "標題列應該一律是重新載入")
        XCTAssertFalse(element("conversation.stop", in: app).exists, "標題列不該再有停止")
        XCTAssertTrue(element("composer.send", in: app).exists, "送出鈕應該維持原樣")

        let stop = element("stopBar.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "工作中沒有停止列的停止鈕")
        XCTAssertEqual(stop.label, "Stop Codex")
        stop.tap()

        let stopping = element("stopBar.stopping", in: app)
        XCTAssertTrue(stopping.waitForExistence(timeout: 2), "按下後沒有顯示停止中")
        XCTAssertFalse(stopping.isEnabled, "停止中應該停用")

        let result = element("stopBar.result", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 10), "停下後沒有顯示結果")
        XCTAssertTrue(result.label.contains("Stopped"), "結果應該是已停止：\(result.label)")
        XCTAssertTrue(element("stopBar", in: app).waitForNonExistence(timeout: 6), "已停止沒有自動收起")
        XCTAssertTrue(working.waitForNonExistence(timeout: 10), "停下後指示沒有消失")
    }

    /// 長按停止鈕開出選單，「Force Quit…」要先在確認對話框確認才送 Ctrl-C。
    @MainActor
    func testForceQuitFromLongPressNeedsConfirmation() {
        let app = open(paneID: "w3:p1")
        let stop = element("stopBar.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10))

        stop.press(forDuration: 1.0)
        let menuItem = app.buttons["Force Quit…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "長按沒有強制結束的選項")
        menuItem.tap()

        let confirm = app.buttons["stopBar.forceQuit.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "強制結束沒有先確認")
        XCTAssertTrue(app.staticTexts["Force Quit Codex?"].exists, "確認對話框標題不對")
        confirm.tap()

        XCTAssertTrue(element("conversation.working", in: app).waitForNonExistence(timeout: 15), "強制結束後仍在工作")
        XCTAssertTrue(element("stopBar", in: app).waitForNonExistence(timeout: 10), "強制結束後停止列還在")
    }

    /// 「需要你」的 agent 永不中斷：沒有停止列。
    @MainActor
    func testNeedsYouAgentHasNoStopBar() {
        let app = open(paneID: "w2:p1")
        XCTAssertTrue(element("conversation.reload", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("conversation.header", in: app).label.hasPrefix("Needs"), "應該是需要你")
        XCTAssertFalse(element("stopBar", in: app).exists, "需要你不該有停止列")
    }
}
