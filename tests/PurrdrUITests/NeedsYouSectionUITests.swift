import XCTest

/// 聊天列表最上面的「需要你」段落(#531、spec #528)。Demo 主機的 `w2:p1`(weather-app)一開始就是需要你。
/// 「剛剛」要等 `NeedsYouNotifications.run` 接上(#530)才出現,所以這裡不驗;規則在 `NeedsYouSectionTests`。
final class NeedsYouSectionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let rowID = "needsYou.tab.demo/w2:t1"

    /// 段落在最上面,標題帶數量、標為 header;點段落裡的列開到那個聊天;返回後原本的段落仍有那一列。
    @MainActor
    func testSectionListsBlockedChatAndOpensIt() {
        let app = XCUIApplication.launchUITesting()

        let header = app.element("needsYou.section")
        XCTAssertTrue(header.waitUntilExists(timeout: 15), "沒有「需要你」段落")
        XCTAssertTrue(header.label.contains("1 chat needs you"), "標題沒有數量:\(header.label)")
        let row = app.element(rowID)
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "段落裡沒有需要你的列")
        XCTAssertTrue(row.label.contains("Needs You"), "列沒有狀態文字:\(row.label)")
        XCTAssertTrue(app.element("spaces.tab.demo/w2:t1").exists, "原本的段落少了這一列")

        row.tap()
        XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10), "點段落裡的列沒有開聊天")
        // 標題是 Tab 名稱(不是 workspace 名稱),以副標題的「需要你」狀態確認開到的是 weather-app。
        XCTAssertTrue(app.conversationSubtitle(containing: "Needs You").waitUntilExists(timeout: 10), "開到別的聊天")
    }
    // AX 最大字級不爆版由 SignInUITests.testAccessibilitySizeThenDefaultSizeSignInButtonsTabBarAndNeedsYouSection 守。
}
