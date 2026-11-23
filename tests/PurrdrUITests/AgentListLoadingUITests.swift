import XCTest

/// 聊天列表的載入中與離線(#221):不整頁轉圈;還在連的主機各一行「連線中」,太久「仍在連線」與再試一次;沒網路直接離線畫面。
final class AgentListLoadingUITests: XCTestCase {
    static let studio = "5EED0000-0000-4000-8000-000000000001"
    static let slowBox = "5EED0000-0000-4000-8000-000000000004"

    override func setUp() {
        continueAfterFailure = false
    }


    /// 一台主機連線卡住：其他台的列照常顯示，卡住的那台一行「連線中」;超過 10 秒換成「仍在連線」與再試一次，按了回到連線中。
    @MainActor
    func testSlowHostShowsConnectingThenStillConnecting() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedSlowHost"])

        XCTAssertTrue(app.element("spaces.tab.\(Self.studio)/w2:t1").waitUntilExists(timeout: 15), "卡住的主機擋住了其他台的列")
        let status = app.element("agentList.host.\(Self.slowBox)")
        XCTAssertTrue(status.waitUntilExists(timeout: 5), "沒有卡住那台主機的連線狀態行")
        XCTAssertTrue(status.label.contains("Slow Box"), status.label)
        XCTAssertTrue(status.label.contains("Connecting…"), status.label)
        XCTAssertFalse(app.staticTexts["Loading agents…"].exists, "還是整頁轉圈")

        let retry = app.element("agentList.host.\(Self.slowBox).retry")
        XCTAssertTrue(retry.waitUntilExists(timeout: 15), "連線超過 10 秒沒有「再試一次」")
        XCTAssertTrue(status.label.contains("Still connecting…"), status.label)

        retry.tap()
        XCTAssertTrue(retry.waitUntilGone(timeout: 5), "按了再試一次沒有回到連線中")
        XCTAssertTrue(status.label.contains("Connecting…"), status.label)
    }

    /// 裝置沒有網路、主機連線會卡 10 秒：不等逾時，立刻顯示離線畫面與再試一次。
    @MainActor
    func testNoNetworkShowsOfflineImmediately() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoNoNetwork"])

        let offline = app.element("agentList.offline")
        XCTAssertTrue(offline.waitUntilExists(timeout: 5), "沒網路時沒有立刻顯示離線畫面")
        XCTAssertTrue(app.buttons["agentList.retry"].firstMatch.exists, "離線畫面沒有再試一次")

        app.buttons["agentList.retry"].firstMatch.tap()
        XCTAssertTrue(offline.waitUntilExists(timeout: 5), "還是沒網路時再試一次後不該離開離線畫面")
    }
}
