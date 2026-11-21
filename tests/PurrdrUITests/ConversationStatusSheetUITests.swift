import XCTest

/// 聊天狀態 sheet 與降噪(#349):頂列一行狀態，點標題開狀態 sheet;工作中只有膠囊一處，背景子 Agent 併進膠囊、清單在 sheet。
final class ConversationStatusSheetUITests: XCTestCase {
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

    /// 點標題一律開得了狀態 sheet(沒有 context 與待辦也一樣，顯示空狀態);完成關閉。
    @MainActor
    func testTitleOpensStatusSheet() {
        let app = open(paneID: "w1:p1")
        let header = element("conversation.header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 10))

        header.tap()

        XCTAssertTrue(element("status.sheet", in: app).waitForExistence(timeout: 5), "點標題沒有開出狀態 sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(element("status.sheet", in: app).waitForNonExistence(timeout: 5), "完成後狀態 sheet 還在")
    }

    /// 工作中只有一顆膠囊(同一資訊只出現一處);背景 agents 列已移除，清單在狀態 sheet。
    @MainActor
    func testWorkingShownOnceAndNoBackgroundBar() {
        let app = open(paneID: "w3:p1")
        XCTAssertTrue(element("conversation.working", in: app).waitForExistence(timeout: 10), "工作中沒有指示")

        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "conversation.working").count, 1, "工作中應只出現一處")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "stopBar").count, 1, "膠囊應只有一顆")
        XCTAssertFalse(element("agentsBar", in: app).exists, "背景 agents 列已併進工作中膠囊與狀態 sheet")
    }
}
