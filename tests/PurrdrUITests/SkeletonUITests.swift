import XCTest

/// 骨架畫面(#496):第一次載入、還沒有內容時顯示骨架(VoiceOver 只有一個「載入中」元素);載入完成後換成內容。
/// 只驗行為,不驗外觀。
final class SkeletonUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 後台一直沒回應、沒有上次的會員資料:帳號頁是骨架。
    @MainActor
    func testAccountSkeletonWhileBackendSilent() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingMemberLoading"])
        app.openAccount()
        let skeleton = app.element("account.loading")
        XCTAssertTrue(skeleton.waitUntilExists(timeout: 10), "帳號頁沒有骨架")
        XCTAssertEqual(skeleton.label, "Loading…")
        // 設定不被後台狀態擋住:後台沒回應時帳號頁仍有設定區(purrdr://settings、Cmd-, 開到的要能用)。
        XCTAssertTrue(app.element("settings.appearance").waitUntilExists(timeout: 5), "後台沒回應時帳號頁沒有設定區")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "account.loading").count, 1, "骨架只該有一個「載入中」元素")
    }
}
