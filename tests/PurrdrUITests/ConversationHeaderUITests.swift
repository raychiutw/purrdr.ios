import XCTest

/// 對話標題列資訊、重新載入、停止列(#44、#220)、工作中指示;強制結束的確認併在 `DelegationUITests`(同一次啟動,Demo 的 notes 一次啟動只能停一次)。資料來自 Demo 主機:停止只送到 Demo 的假 agent。
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

        // 工作中只有一顆膠囊(同一資訊只出現一處);背景 agents 列已移除，清單在「⋯」→ 背景子 Agent。
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "conversation.working").count, 1, "工作中應只出現一處")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "stopBar").count, 1, "膠囊應只有一顆")
        XCTAssertFalse(app.element("agentsBar").exists, "背景 agents 列已併進工作中膠囊與「⋯」選單")
        // 工作中膠囊浮在輸入框上方，在左右 16pt 邊界內(不是貼齊螢幕的色塊)。
        let bar = app.element("stopBar")
        let card = app.element("composer.card")
        XCTAssertTrue(card.waitUntilExists(timeout: 5), "輸入框沒有玻璃卡片")
        XCTAssertLessThanOrEqual(bar.frame.maxY, card.frame.minY + 1, "膠囊應在輸入框上方")
        XCTAssertGreaterThanOrEqual(bar.frame.minX, 15, "膠囊超出左右邊界")

        stop.tap()

        let stopping = app.element("stopBar.stopping")
        // 「停止中不能重按」由 ConversationHeaderTests 守(停止中不到 1 秒,UI 測試量 isEnabled 會找不到元素)。
        let result = app.element("stopBar.result")
        // 停止中不到 1 秒：用輪詢等「停止中」或「結果」其中之一出現(快的話停止中已過,直接是結果),不在點完立刻只查一次。
        XCTAssertTrue(UITestWait.until(timeout: 10) { stopping.exists || result.exists }, "按下後沒有顯示停止中或結果")

        XCTAssertTrue(result.waitUntilExists(timeout: 10), "停下後沒有顯示結果")
        XCTAssertTrue(result.label.contains("Stopped"), "結果應該是已停止：\(result.label)")
        XCTAssertTrue(app.element("stopBar").waitUntilGone(timeout: 6), "已停止沒有自動收起")
        XCTAssertTrue(working.waitUntilGone(timeout: 5), "停下後指示沒有消失")
    }
}
