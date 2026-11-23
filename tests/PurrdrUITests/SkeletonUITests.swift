import XCTest

/// 骨架畫面(#496):第一次載入、還沒有內容時顯示骨架(VoiceOver 只有一個「載入中」元素);載入完成後換成內容。
/// 只驗行為,不驗外觀。
final class SkeletonUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 只有一台連線卡住的主機:聊天列表停在列表骨架,主機 tab 的狀態卡也是骨架。
    @MainActor
    func testSlowHostShowsListAndStatusSkeleton() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedSlowHost"])
        let list = app.element("agentList.loading.skeleton")
        XCTAssertTrue(list.waitUntilExists(timeout: 10), "聊天列表第一次載入沒有骨架")
        XCTAssertEqual(list.label, "Loading…", "骨架念的不是「載入中」")

        app.openHostsTab()
        let status = app.element("hosts.status.skeleton")
        XCTAssertTrue(status.waitUntilExists(timeout: 10), "主機頁狀態卡沒有骨架")
        XCTAssertEqual(status.label, "Loading…")
    }

    /// 對話紀錄一直讀不完:對話停在骨架,輸入列照常可用。
    @MainActor
    func testConversationSkeletonWhileLoading() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoTranscriptPending"])
        XCTAssertTrue(app.element("conversation.loading").waitUntilExists(timeout: 10), "沒有對話骨架")
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 5), "骨架時輸入列不可用")
    }

    /// 正常載入的對話:載入完成後沒有骨架。
    @MainActor
    func testConversationSkeletonGoneAfterLoad() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1")
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 10))
        XCTAssertTrue(app.element("conversation.loading").waitUntilGone(timeout: 10), "載入完成後骨架沒有消失")
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
