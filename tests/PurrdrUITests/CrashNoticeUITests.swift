import XCTest

/// 啟動提示「上次 Purrdr 意外關閉」(#632、spec #629):旗標 `-uiTestingCrashRecord` 預放一筆閃退記錄。
final class CrashNoticeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// 提示出現、「分享記錄」開出系統分享、「關閉」後不再出現。
    @MainActor
    func testLaunchNoticeSharesAndDismisses() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingCrashRecord"])
        let banner = app.otherElements["crashNotice.banner"]
        XCTAssertTrue(banner.waitUntilExists(timeout: 10), "沒有「上次意外關閉」提示")

        app.buttons["crashNotice.share"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitUntilExists(timeout: 10), "沒有開出系統分享")
        // 分享選單是 popover(iPhone 模擬器):第一下點選單外側(正好是「關閉」鈕)只會收起選單,提示還在;再點一次才關閉提示。
        let dismiss = app.buttons["crashNotice.dismiss"]
        XCTAssertTrue(dismiss.waitUntilExists(timeout: 10), "分享後提示不該消失")
        for _ in 0..<3 where banner.exists {
            dismiss.tap()
            _ = banner.waitUntilGone(timeout: 3)
        }
        XCTAssertTrue(banner.waitUntilGone(timeout: 5), "關閉後提示還在")
    }

    /// 按「關閉」後重新啟動 app,同一筆閃退不再提示(`-uiTestingKeepCrashNotice` 讓已提示狀態跨啟動保留)。
    @MainActor
    func testDismissedNoticeStaysGoneAfterRelaunch() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingCrashRecord"])
        XCTAssertTrue(app.otherElements["crashNotice.banner"].waitUntilExists(timeout: 10), "沒有「上次意外關閉」提示")
        app.buttons["crashNotice.dismiss"].tap()
        XCTAssertTrue(app.otherElements["crashNotice.banner"].waitUntilGone(timeout: 5))
        app.terminate()

        let relaunched = XCUIApplication.launchUITesting(flags: ["-uiTestingCrashRecord", "-uiTestingKeepCrashNotice"])
        XCTAssertTrue(relaunched.element("topBar.title").waitUntilExists(timeout: 10), "app 沒有重新啟動")
        XCTAssertFalse(relaunched.otherElements["crashNotice.banner"].waitUntilExists(timeout: 3), "關閉過的提示重啟後又出現")
    }

    /// 提示顯示出來就記為已提示:沒按關閉就結束 app,下次啟動也不再提示。
    @MainActor
    func testShownNoticeIsNotRepeatedAfterRelaunchWithoutDismiss() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingCrashRecord"])
        XCTAssertTrue(app.otherElements["crashNotice.banner"].waitUntilExists(timeout: 10), "沒有「上次意外關閉」提示")
        app.terminate()

        let relaunched = XCUIApplication.launchUITesting(flags: ["-uiTestingCrashRecord", "-uiTestingKeepCrashNotice"])
        XCTAssertTrue(relaunched.element("topBar.title").waitUntilExists(timeout: 10), "app 沒有重新啟動")
        XCTAssertFalse(relaunched.otherElements["crashNotice.banner"].waitUntilExists(timeout: 3), "顯示過的提示重啟後又出現")
    }

    /// 沒有閃退記錄時不提示。
    @MainActor
    func testNoNoticeWithoutCrash() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertFalse(app.otherElements["crashNotice.banner"].waitUntilExists(timeout: 3))
    }

    /// 設定的「診斷記錄」在有閃退記錄時可分享(開出系統分享,不是「還沒有記錄」)。
    @MainActor
    func testSettingsDiagnosticLogCanShareCrash() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingCrashRecord"])
        XCTAssertTrue(app.buttons["crashNotice.dismiss"].waitUntilExists(timeout: 10))
        app.buttons["crashNotice.dismiss"].tap()
        app.openSettingsSheet()
        let share = app.buttons["settings.hitchLog.share"]
        app.scrollIntoView(share, search: .down)
        XCTAssertTrue(share.waitUntilExists(timeout: 5))
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitUntilExists(timeout: 10), "有閃退記錄時應開出分享")
        XCTAssertFalse(app.staticTexts["settings.hitchLog.empty"].exists)
    }
}
