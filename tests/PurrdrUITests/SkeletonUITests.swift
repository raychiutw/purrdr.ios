import XCTest

/// 骨架畫面(#496):第一次載入、還沒有內容時顯示骨架(VoiceOver 只有一個「載入中」元素);載入完成後換成內容。
/// 只驗行為,不驗外觀。
final class SkeletonUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 正常載入的對話:讀取在骨架出現前(約 300 毫秒留白)就完成,整段過程都不該出現骨架,訊息出現後也不該再有。
    /// (只等「骨架消失」守不到問題:正常載入骨架根本不會出現,卡住的骨架也要等到逾時才消失。所以輪詢整段看有沒有出現過。)
    @MainActor
    func testConversationNeverShowsSkeletonOnNormalLoad() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        let loading = app.element("conversation.loading")
        let message = app.element("conversation.user")
        var sawSkeleton = false
        var sawMessage = false
        _ = UITestWait.until(timeout: 10) {
            if loading.exists { sawSkeleton = true }
            if message.exists { sawMessage = true }
            return sawMessage
        }
        XCTAssertTrue(sawMessage, "對話沒有載入出訊息")
        // 訊息出現之後再多看一會兒(骨架若是延後才冒出來也要抓到)。
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if loading.exists { sawSkeleton = true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(sawSkeleton, "正常載入的對話出現了骨架")
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
