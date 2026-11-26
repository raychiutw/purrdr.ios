import XCTest

/// 背景→回前景(#550、#551):回來時列表立刻有內容、不閃「連線中」,不論背景多久。
/// 保留期內(短暫離開)連線沿用;超過保留時間(25 秒)回來會直接丟棄並預先撥號,列表沿用最後的快照。
/// 兩條路的「重撥或沿用」決策與連線動作由 `ConnectionRecoveryTests`、`BackgroundRetentionModelTests` 在 model 層用假連線與注入時間守住;
/// UI 層看不到連線是否被重撥(沒有可觀察的畫面差異),所以這裡守的是使用者看得到的結果。
final class ForegroundReturnUITests: XCTestCase {
    private let ledger = "spaces.tab.demo/w1:t1"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func goToBackgroundAndBack(_ app: XCUIApplication, seconds: TimeInterval) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "app 沒有進背景")
        Thread.sleep(forTimeInterval: seconds)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app 沒有回到前景")
    }

    /// 回前景後約 1 秒內:列表還在、沒有「連線中」的主機列(安靜重連前 1.5 秒不顯示)。
    @MainActor
    private func assertListIntactAfterReturn(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.element(ledger).waitUntilExists(timeout: 5), "回前景後列表沒有內容", file: file, line: line)
        let connecting = UITestWait.until(timeout: 1) { app.element("agentList.host.demo").exists }
        XCTAssertFalse(connecting, "回前景後閃出「連線中」", file: file, line: line)
        XCTAssertTrue(app.element(ledger).exists, "列表被清空", file: file, line: line)
    }

    @MainActor
    func testReturningWithinRetentionKeepsListWithoutConnecting() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.element(ledger).waitUntilExists(timeout: 15))

        goToBackgroundAndBack(app, seconds: 3)

        assertListIntactAfterReturn(app)
    }

}
