import XCTest

/// 聊天右上用量環的載入動畫(#644,spec #612):一進聊天就是系統載入動畫,讀完換成環。
/// `-demoUsageReadDelayed`:Demo 主機把用量(session 狀態)讀取延後 6 秒才回應,載入期間可確定性地斷言。
final class ConversationUsageLoadingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 載入中(按鈕把裡面的系統載入動畫併成一個元素,值是「Loading」)、位置固定、仍可點開面板;
    /// 讀取回應之後換成結果(值不再是 Loading),用量環還在、位置與大小不變。
    @MainActor
    func testLoadingThenSettlesWithoutMovingTheRing() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoUsageReadDelayed"])
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 15), "沒有用量環")
        XCTAssertEqual(ring.value as? String, "Loading", "一進聊天右上就該是載入動畫(讀取要 6 秒才回應)")
        let loadingFrame = ring.frame

        // 載入期間仍可開面板。
        ring.tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "載入期間點用量環要能開面板")
        app.buttons["panel.close"].tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilGone(timeout: 5))

        // 讀取回應後(延遲到了)換成結果:用過「必須先看到 Loading」才能走到這裡,所以不是恆真。
        let settled = NSPredicate(format: "value != %@", "Loading")
        expectation(for: settled, evaluatedWith: ring)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(ring.exists, "載入結束後用量環要還在")
        XCTAssertEqual(ring.frame.size.width, loadingFrame.size.width, accuracy: 1, "三種狀態圓圈大小要一致")
        XCTAssertEqual(ring.frame.minX, loadingFrame.minX, accuracy: 1, "載入結束不該造成頂列位移")
        XCTAssertEqual(ring.frame.minY, loadingFrame.minY, accuracy: 1)
    }
}
