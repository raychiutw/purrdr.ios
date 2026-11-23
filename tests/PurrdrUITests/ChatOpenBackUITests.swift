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

    /// 打開聊天再回列表;導覽入口旁不放數字徽章(#322)。
    @MainActor
    func testOpeningChatAndGoingBackKeepsList() {
        let app = XCUIApplication.launchUITesting()
        let ledger = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(ledger))

        // 有需要你的 workspace 時，主機與設定 sheet 的「完成」旁也不放數字徽章(#322)。
        // 導覽入口(主機、設定 tab)旁不放數字徽章(#322);聊天 tab 的 badge 是「需要你」數(#390)。
        for tab in [AppTab.hosts, .settings] {
            app.openTab(tab)
            XCTAssertFalse(app.descendants(matching: .any)["attention.badge"].firstMatch.exists, "\(tab.rawValue) 旁有數字徽章")
        }
        app.openTab(.chats)

        ledger.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.reveal(row("w1:p1", in: app)), "回到列表後沒有看到那一列")
    }
}
