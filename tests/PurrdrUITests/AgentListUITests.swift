import XCTest

final class AgentListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[chatRowID(paneID)].firstMatch
    }

    /// 聊天列表頂部(#615):系統導覽列。大標題、右側 [電腦圖示｜＋] 與頭像(由左到右),系統搜尋欄(平常收起、往下拉才出現);
    /// 往上滑時系統收合大標題,回到頂端大標題回來。
    @MainActor
    func testChatListTopBarCollapsesOnScroll() {
        // 字級調大讓 Spaces 的列夠多、列表高過畫面才捲得動(Demo 的列不多)。
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"], contentSize: "UICTContentSizeCategoryXXXL")
        XCTAssertTrue(app.reveal(row("w1:p1", in: app)))
        let title = app.topBarTitle("Chats")
        XCTAssertTrue(title.waitUntilExists(timeout: 5), "沒有大標題")
        let host = app.buttons["toolbar.currentHost"].firstMatch
        let newChat = app.buttons["toolbar.newChat"].firstMatch
        let account = app.buttons["toolbar.account"].firstMatch
        XCTAssertTrue(host.exists && newChat.exists && account.exists, "頂列缺控制項")
        XCTAssertLessThan(host.frame.minX, newChat.frame.minX, "電腦圖示不在＋左邊")
        XCTAssertLessThan(newChat.frame.minX, account.frame.minX, "＋不在頭像左邊")
        XCTAssertTrue(app.navigationBars.firstMatch.exists, "系統導覽列不見了")

        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        XCTAssertTrue(app.revealChatSearch().exists, "往下拉後沒有搜尋欄(平常收起)")
        XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "往下滑後頭像不見了")

        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(title.waitUntilExists(timeout: 5), "回到頂端後大標題沒有回來")
    }

    /// AX 字級下 4 個 tab 都在 tab bar 上,帳號與新增聊天仍可從工具列(或溢出選單)點到。
    @MainActor
    func testTabBarAndAccountReachableAtAccessibilitySize() {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.chatListReady.waitUntilExists(timeout: 15))
        for tab in [AppTab.chats, .files, .hosts, .traffic] {
            XCTAssertTrue(
                app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", tab.rawValue)).firstMatch.waitUntilExists(timeout: 5),
                "tab bar 沒有 \(tab.rawValue)")
        }
        // 未登入時帳號鈕開的是「登入或加入」選擇頁(#408),不是帳號頁。
        app.openAccount()
        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "大字級下沒有開出登入或加入選擇頁")
        let signIn = app.buttons["account.entry.signIn"]
        app.scrollIntoView(signIn, search: .down)
        XCTAssertTrue(signIn.waitUntilExists(timeout: 5), "大字級下找不到「登入」")
    }

    /// 右上角的帳號圓圈與同列的系統工具列鈕一樣高(#615:都是系統玻璃鈕,不自加尺寸;XCUI 的 frame 只報內容 36pt)。
    @MainActor
    func testAccountButtonMatchesMoreButton() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"].firstMatch
        XCTAssertTrue(account.waitUntilExists(timeout: 10))
        let newChat = app.buttons["toolbar.newChat"].firstMatch
        XCTAssertEqual(account.frame.height, newChat.frame.height, accuracy: 1, "帳號圓圈 \(account.frame) 與工具列鈕 \(newChat.frame) 不一樣高")
    }
}
