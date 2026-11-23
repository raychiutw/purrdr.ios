import XCTest

/// 聊天狀態 sheet 與降噪(#349):頂列一行狀態，點標題開狀態 sheet;工作中只有膠囊一處，背景子 Agent 併進膠囊、清單在 sheet。
final class ConversationStatusSheetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 點標題一律開得了狀態 sheet(沒有 context 與待辦也一樣，顯示空狀態);完成關閉。
    @MainActor
    func testTitleOpensStatusSheet() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let header = app.element("conversation.header")
        XCTAssertTrue(header.waitUntilExists(timeout: 10))

        header.tap()

        XCTAssertTrue(app.element("status.sheet").waitUntilExists(timeout: 5), "點標題沒有開出狀態 sheet")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.element("status.sheet").waitUntilGone(timeout: 5), "完成後狀態 sheet 還在")
    }

    /// 工作中只有一顆膠囊(同一資訊只出現一處);背景 agents 列已移除，清單在狀態 sheet。
    @MainActor
    func testWorkingShownOnceAndNoBackgroundBar() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")
        XCTAssertTrue(app.element("conversation.working").waitUntilExists(timeout: 10), "工作中沒有指示")

        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "conversation.working").count, 1, "工作中應只出現一處")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "stopBar").count, 1, "膠囊應只有一顆")
        XCTAssertFalse(app.element("agentsBar").exists, "背景 agents 列已併進工作中膠囊與狀態 sheet")
    }
}
