import XCTest

/// 啟動提示「上次 Purrdr 意外關閉」(#632、spec #629):旗標 `-uiTestingCrashRecord` 預放一筆閃退記錄。
final class CrashNoticeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// 提示出現、「分享記錄」開出系統分享、「關閉」後不再出現;接著設定的「診斷記錄」同樣可分享閃退記錄。
    @MainActor
    func testLaunchNoticeSharesDismissesThenSettingsDiagnosticLogSharesCrash() {
        let app = XCUIApplication.launchUITesting(flags: [.uiTestingCrashRecord])
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

        // 設定的「診斷記錄」在有閃退記錄時可分享(開出系統分享,不是「還沒有記錄」)。
        app.openSettingsSheet()
        let share = app.buttons["settings.hitchLog.share"]
        app.scrollIntoView(share, search: .down)
        XCTAssertTrue(share.waitUntilExists(timeout: 5))
        share.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitUntilExists(timeout: 10), "有閃退記錄時應開出分享")
        XCTAssertFalse(app.staticTexts["settings.hitchLog.empty"].exists)
    }
}
