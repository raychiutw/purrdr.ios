import XCTest

/// 聊天右上用量環的載入動畫(#644,spec #612):一進聊天就是系統載入動畫,讀完換成環。
/// `-demoUsageReadDelayed`:Demo 主機把用量(session 狀態)讀取延後 6 秒才回應,讓載入動畫有機會出現。
/// 6 秒是固定窗,Debug 冷啟動加導航可能超過它;錯過窗時**明確 skip**(不是失敗,也不靜靜通過成恆真),
/// 取樣到「Loading」才驗載入前後用量環的位置與大小不變、載入期間可開面板、最後一定換成結果。
final class ConversationUsageLoadingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 載入期間(若還在載入,值是「Loading」)位置固定、仍可點開面板;
    /// 讀取回應之後換成結果(值不再是 Loading),用量環還在、位置與大小不變。
    @MainActor
    func testLoadingThenSettlesWithoutMovingTheRing() throws {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: [.demoUsageReadDelayed], viaLink: true)
        let ring = app.buttons["conversation.usage"].firstMatch
        XCTAssertTrue(ring.waitUntilExists(timeout: 15), "沒有用量環")
        guard ring.value as? String == "Loading" else {
            throw XCTSkip("載入窗(6 秒)已過,這次無法驗證載入中的位置;skip 次數多時回頭檢查窗長")
        }
        let loadingFrame = ring.frame

        // 載入期間仍可開面板。
        ring.tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "載入期間點用量環要能開面板")
        app.buttons["panel.close"].tap()
        XCTAssertTrue(app.element("conversation.panel").waitUntilGone(timeout: 5))

        // 讀取回應後(延遲到了)換成結果。
        XCTAssertTrue(UITestWait.until(timeout: 30) { (ring.value as? String) != "Loading" }, "讀取回應後用量環仍是載入中")
        XCTAssertTrue(ring.exists, "載入結束後用量環要還在")
        XCTAssertEqual(ring.frame.size.width, loadingFrame.size.width, accuracy: 1, "三種狀態圓圈大小要一致")
        XCTAssertEqual(ring.frame.minX, loadingFrame.minX, accuracy: 1, "載入結束不該造成頂列位移")
        XCTAssertEqual(ring.frame.minY, loadingFrame.minY, accuracy: 1)
    }
}
