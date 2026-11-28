import XCTest

/// 啟動看門狗(#718):用真的 app 驗證「正常啟動不重來」與「第一次沒就緒就結束 app 後重來」。
/// 純邏輯(上限、崩潰不重來、訊息)在 `swift test` 的 `LaunchWatchdogTests`。
final class LaunchWatchdogUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNormalLaunchDoesNotRetry() {
        var logs: [String] = []
        let app = XCUIApplication.uiTesting()
        app.launchWithWatchdog(log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty, "正常啟動不該重來:\(logs)")
        XCTAssertTrue(app.buttons["toolbar.newChat"].firstMatch.waitUntilExists(timeout: 10), "啟動後沒有聊天列表")
    }

    @MainActor
    func testRetriesWhenFirstLaunchIsNotReady() {
        var logs: [String] = []
        let app = XCUIApplication.uiTesting()
        // 第一次啟動刻意不就緒、等待縮短成 2 秒:看門狗要結束 app、重啟,第二次就緒後通過。
        app.launchWithWatchdog(
            policy: LaunchWatchdogPolicy(readinessTimeout: 2, maxAttempts: 2), forcedUnready: 1, log: { logs.append($0); print($0) })
        XCTAssertEqual(logs.count, 1, "應該恰好重來一次:\(logs)")
        XCTAssertTrue(logs.first?.contains("重來") == true, "記錄沒寫重來:\(logs)")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["toolbar.newChat"].firstMatch.waitUntilExists(timeout: 10), "重來後沒有聊天列表")
    }
}
