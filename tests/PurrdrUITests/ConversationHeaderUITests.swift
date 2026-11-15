import XCTest

/// 對話標題列資訊、重新載入與停止、工作中指示(#44)。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
final class ConversationHeaderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func open(paneID: String) -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.\(paneID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
        row.tap()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 標題下一行有狀態與 agent 名稱(VoiceOver 念完整內容);不在工作中時有「重新載入」,點了重讀對話。
    @MainActor
    func testHeaderShowsInfoAndReloadRereads() {
        let app = open(paneID: "w1:p1")
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10))

        let header = element("conversation.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 5), "標題下沒有資訊行")
        XCTAssertTrue(header.label.hasPrefix("Done"), "資訊行沒有狀態字：\(header.label)")
        XCTAssertTrue(header.label.contains("Claude Code"), "資訊行沒有 agent 名稱：\(header.label)")
        XCTAssertFalse(element("conversation.stop", in: app).exists, "不在工作中不該有停止")

        let reload = element("conversation.reload", in: app)
        XCTAssertTrue(reload.exists, "沒有重新載入")
        XCTAssertEqual(reload.label, "Reload")
        reload.tap()
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10), "重新載入後沒有重讀對話")
    }

    /// 工作中：底部有指示與即時預覽、標題列是「停止」;點一下送 Esc,agent 停下後換回「重新載入」、指示消失。
    @MainActor
    func testWorkingAgentShowsIndicatorAndStops() {
        let app = open(paneID: "w3:p1")

        let working = element("conversation.working", in: app)
        XCTAssertTrue(working.waitForExistence(timeout: 10), "工作中沒有指示")
        XCTAssertTrue(element("conversation.livePreview", in: app).exists, "沒有即時預覽")
        XCTAssertTrue(element("conversation.header", in: app).label.hasPrefix("Working"))
        XCTAssertFalse(element("conversation.reload", in: app).exists, "工作中不該有重新載入")

        let stop = element("conversation.stop", in: app)
        XCTAssertTrue(stop.exists, "工作中沒有停止")
        stop.tap()

        XCTAssertTrue(element("conversation.reload", in: app).waitForExistence(timeout: 15), "停下後沒有換回重新載入")
        XCTAssertTrue(working.waitForNonExistence(timeout: 10), "停下後指示沒有消失")
    }

    /// 長按停止打開選單(說明與「強制結束」),選了才送 Ctrl-C。
    @MainActor
    func testLongPressStopOffersForceQuit() {
        let app = open(paneID: "w3:p1")
        let stop = element("conversation.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10))

        stop.press(forDuration: 1.0)
        let forceQuit = app.buttons["Force Quit Agent"]
        XCTAssertTrue(forceQuit.waitForExistence(timeout: 5), "長按沒有強制結束的選項")
        forceQuit.tap()

        XCTAssertTrue(element("conversation.reload", in: app).waitForExistence(timeout: 15), "強制結束後沒有換回重新載入")
    }
}
