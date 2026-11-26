import XCTest

/// 聊天右上用量環的載入動畫(#644,spec #612):一進聊天就是系統載入動畫,讀完換成環。
final class ConversationUsageLoadingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 用量讀取一直沒回應(`-demoUsageReadPending`):載入動畫在用量環的位置,載入期間仍可點開聊天面板。
    @MainActor
    func testLoadingIndicatorShownWhileUsageIsPending() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoUsageReadPending"])
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 15), "沒有用量環")
        // 按鈕把裡面的系統載入動畫併成一個元素,所以以按鈕的值「Loading」確認載入中。
        XCTAssertEqual(ring.value as? String, "Loading", "載入中 VoiceOver 要念「讀取中」")

        ring.tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "載入期間點用量環要能開面板")
    }

    /// 一般情況:讀完之後載入動畫消失,用量環還在(位置不變、不消失)。
    @MainActor
    func testLoadingIndicatorGoesAwayAfterUsageIsRead() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 15), "沒有用量環")
        let settled = NSPredicate(format: "value != %@", "Loading")
        expectation(for: settled, evaluatedWith: ring)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(ring.exists, "載入結束後用量環要還在")
        XCTAssertNotEqual(ring.value as? String, "Loading")
    }
}
