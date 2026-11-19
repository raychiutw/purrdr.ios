import XCTest

/// 對話標題列資訊、重新載入、停止與強制結束(#44、#220)、工作中指示。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
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

    /// 標題下一行有狀態與 agent 名稱(VoiceOver 念完整內容);標題列是「重新載入」,點了重讀對話。
    @MainActor
    func testHeaderShowsInfoAndReloadRereads() {
        let app = open(paneID: "w1:p1")
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10))

        let header = element("conversation.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 5), "標題下沒有資訊行")
        XCTAssertTrue(header.label.hasPrefix("Done"), "資訊行沒有狀態字：\(header.label)")
        XCTAssertTrue(header.label.contains("Claude Code"), "資訊行沒有 agent 名稱：\(header.label)")
        XCTAssertFalse(element("composer.stop", in: app).exists, "不在工作中不該有停止")
        XCTAssertFalse(element("conversation.more", in: app).exists, "不在工作中不該有強制結束選單")

        let reload = element("conversation.reload", in: app)
        XCTAssertTrue(reload.exists, "沒有重新載入")
        XCTAssertEqual(reload.label, "Reload")
        reload.tap()
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10), "重新載入後沒有重讀對話")
    }

    /// 工作中(#220):底部有指示與即時預覽;輸入列的送出鈕換成停止鈕，標題列仍是「重新載入」。
    /// 點一下送 Esc,停止中按鈕念「Stopping」且不能重按，agent 停下後換回送出鈕、指示消失。
    @MainActor
    func testWorkingAgentStopsFromComposer() {
        let app = open(paneID: "w3:p1")

        let working = element("conversation.working", in: app)
        XCTAssertTrue(working.waitForExistence(timeout: 10), "工作中沒有指示")
        XCTAssertTrue(element("conversation.livePreview", in: app).exists, "沒有即時預覽")
        XCTAssertTrue(element("conversation.header", in: app).label.hasPrefix("Working"))
        XCTAssertTrue(element("conversation.reload", in: app).exists, "標題列應該一律是重新載入")
        XCTAssertFalse(element("conversation.stop", in: app).exists, "標題列不該再有停止")

        let stop = element("composer.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "工作中輸入列沒有停止鈕")
        XCTAssertEqual(stop.label, "Stop")
        XCTAssertFalse(element("composer.send", in: app).exists, "停止鈕應該取代送出鈕")
        stop.tap()

        let stopping = NSPredicate(format: "label == %@ AND isEnabled == false", "Stopping")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: stopping, evaluatedWith: stop)], timeout: 2), .completed, "按下後沒有顯示停止中")

        XCTAssertTrue(element("composer.send", in: app).waitForExistence(timeout: 15), "停下後沒有換回送出鈕")
        XCTAssertFalse(stop.exists, "停下後停止鈕還在")
        XCTAssertTrue(working.waitForNonExistence(timeout: 10), "停下後指示沒有消失")
    }

    /// 強制結束在標題列的選單(#220),選了才送 Ctrl-C。
    @MainActor
    func testForceQuitFromMoreMenu() {
        let app = open(paneID: "w3:p1")
        let more = element("conversation.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 10), "工作中標題列沒有選單")

        more.tap()
        let forceQuit = app.buttons["Force Quit Agent"]
        XCTAssertTrue(forceQuit.waitForExistence(timeout: 5), "選單裡沒有強制結束")
        forceQuit.tap()

        XCTAssertTrue(element("composer.send", in: app).waitForExistence(timeout: 15), "強制結束後沒有換回送出鈕")
        XCTAssertTrue(more.waitForNonExistence(timeout: 5), "強制結束後選單還在")
    }

    /// 「需要你」的 agent 永不中斷：沒有停止鈕，也沒有強制結束。
    @MainActor
    func testNeedsYouAgentOffersNoInterrupt() {
        let app = open(paneID: "w2:p1")
        XCTAssertTrue(element("conversation.reload", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("conversation.header", in: app).label.hasPrefix("Needs"), "應該是需要你：\(element("conversation.header", in: app).label)")

        XCTAssertFalse(element("composer.stop", in: app).exists, "需要你不該有停止鈕")
        XCTAssertFalse(element("conversation.more", in: app).exists, "需要你不該有強制結束")
    }
}
