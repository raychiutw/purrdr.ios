import XCTest

/// 開聊天再回列表、導覽入口旁不放數字徽章(#41、#322),走 Demo 主機。#501 起聊天只有 Spaces:列的未讀標示、釘選與滑動隨 Agents 檢視移除,新列的未讀點由 #502 驗。
final class ChatOpenBackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[chatRowID(paneID)].firstMatch
    }

    /// 窄視窗是一般 NavigationStack:左緣滑動返回列表,再開同一個聊天仍進得去(選取在返回時清掉)。
    @MainActor
    func testEdgeSwipeBackReturnsToListAndChatReopens() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))

        ledger.tap()
        let composer = app.element("composer.text")
        XCTAssertTrue(composer.waitUntilExists(timeout: 10), "點列沒有開聊天")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))

        XCTAssertTrue(composer.waitUntilGone(timeout: 5), "左緣滑動沒有離開聊天(#641)")
        let again = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(again), "左緣滑動後沒有回到列表")
        XCTAssertTrue(again.waitUntilHittable(timeout: 5))
        again.tap()
        XCTAssertTrue(composer.waitUntilExists(timeout: 10), "再次開啟聊天沒有推入")
    }
}
