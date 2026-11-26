import XCTest

/// 聊天「⋯」選單與各項 sheet(#349、#515):原本標題面板的功能搬進「⋯」,點項目開各自的 sheet;工作中只有膠囊一處。
final class ConversationStatusSheetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 「⋯」有用量、權限模式、模型(Claude);權限模式 sheet 用左上 X 關閉。
    @MainActor
    func testMoreMenuListsItemsAndOpensPermissionSheet() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10))

        let permission = app.conversationMoreItem("menu.permissionMode")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Usage & Context")).firstMatch.exists, "「⋯」沒有用量與 Context")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Model & Effort")).firstMatch.exists, "「⋯」沒有模型與思考深度")
        permission.tap()

        XCTAssertTrue(app.element("menu.sheet.permissionMode").waitUntilExists(timeout: 5), "點項目沒有開出權限模式 sheet")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(app.element("menu.sheet.permissionMode").waitUntilGone(timeout: 5), "X 之後 sheet 還在")
    }

    /// 標題不能點(#515):點了不會開任何 sheet。
    @MainActor
    func testTitleIsNotAButton() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10))
        let subtitle = app.conversationSubtitle(containing: "Done")
        XCTAssertTrue(subtitle.waitUntilExists(timeout: 10), "沒有系統副標題")
        subtitle.tap()
        XCTAssertFalse(app.element("menu.sheet.permissionMode").exists)
        XCTAssertFalse(app.element("conversation.panel").exists)
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
