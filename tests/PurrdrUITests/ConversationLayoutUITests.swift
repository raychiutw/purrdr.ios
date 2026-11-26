import XCTest

/// 聊天的 A1 浮動膠囊版面(#348,spec #336):玻璃控制浮在內容上、內容延伸到上下邊緣、輸入框與訊息左右對齊。
/// 截圖(淺色、深色、減少透明度)存成附件 `chat-floating-*`。
final class ConversationLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }


    /// 返回後 tab bar 跟著回來(#495):tab bar 是系統的(`toolbarVisibility`),返回時由系統轉場帶回。
    /// `tap()` 回來時系統轉場的最後一格可能還沒結束,所以不在那一刻只查一次(實測 tab bar 在 tap 回來後約 0.1～0.3 秒才查得到,
    /// 不是 app 的行為:XCUITest 每次查詢本身就要 100～300 ms,舊版量到的「延遲」也是查詢延遲)。
    /// 改驗結果:返回後 tab bar 會變成可點(回得來),而且之後穩定在(沒有閃一下又消失)。
    @MainActor
    private func expectTabBarReturnsWithBack(_ app: XCUIApplication, _ tabBar: XCUIElement, _ label: String) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        back.tap()
        XCTAssertTrue(tabBar.waitUntilHittable(timeout: 3), "\(label):返回後 tab bar 沒有回來")
        XCTAssertFalse(tabBar.waitUntilGone(timeout: 1), "\(label):tab bar 返回後又消失")
    }

    /// 帶動畫從聊天返回列表,tab bar 與列表同時出現;對話裡不能有 tab bar。
    @MainActor
    func testTabBarReturnsTogetherWithListOnBack() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingAnimations"])
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitUntilExists(timeout: 10))
        let row = app.descendants(matching: .any)[chatRowID("w1:p1")].firstMatch
        XCTAssertTrue(app.reveal(row))
        row.tap()
        XCTAssertTrue(app.conversationBar.waitUntilExistsAndSettled(timeout: 15))
        XCTAssertTrue(tabBar.waitUntilGone(timeout: 5), "對話裡不該有 tab bar")
        expectTabBarReturnsWithBack(app, tabBar, "chat")
    }

}
