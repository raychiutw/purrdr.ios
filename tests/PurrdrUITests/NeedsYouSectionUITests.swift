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
        let conversation = app.element("conversation.header")
        XCTAssertTrue(conversation.waitUntilExists(timeout: 10), "點段落裡的列沒有開聊天")
        XCTAssertTrue(conversation.label.contains("weather-app"), "開到別的聊天:\(conversation.label)")
    }

    /// 搜尋時這段也套用搜尋:不符合就整段消失。
    @MainActor
    func testSectionFollowsSearch() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.element("needsYou.section").waitUntilExists(timeout: 15))

        let search = app.chatSearch
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
        search.tap()
        search.typeEnglish("ledger")

        XCTAssertTrue(app.element("needsYou.section").waitUntilGone(timeout: 5), "搜尋不符合,段落仍在")
    }

    /// AX 最大字級不爆版:段落標題與列都還在畫面上。
    @MainActor
    func testSectionAtLargestTextSize() {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")

        let header = app.element("needsYou.section")
        XCTAssertTrue(header.waitUntilExists(timeout: 15), "AX 字級沒有「需要你」段落")
        XCTAssertTrue(app.element(rowID).waitUntilExists(timeout: 5), "AX 字級段落裡沒有列")
        XCTAssertLessThanOrEqual(header.frame.maxX, app.frame.maxX + 1, "標題超出畫面寬度")
    }
}
