import XCTest

/// 聊天「⋯」選單與各項 sheet(#349、#515):原本標題面板的功能搬進「⋯」,點項目開各自的 sheet;工作中只有膠囊一處。
final class ConversationStatusSheetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 工作中只有一顆膠囊(同一資訊只出現一處);背景 agents 列已移除，清單在「⋯」→ 背景子 Agent。
    @MainActor
    func testWorkingShownOnceAndNoBackgroundBar() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w3:p1")
        XCTAssertTrue(app.element("conversation.working").waitUntilExists(timeout: 10), "工作中沒有指示")

        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "conversation.working").count, 1, "工作中應只出現一處")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "stopBar").count, 1, "膠囊應只有一顆")
        XCTAssertFalse(app.element("agentsBar").exists, "背景 agents 列已併進工作中膠囊與「⋯」選單")
    }
}
