import XCTest

final class AgentListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[chatRowID(paneID)].firstMatch
    }

    /// tracer bullet:app → 畫面 model → herdr client → 主機通道(Demo 主機)整條路徑都走正式程式。
    /// 聊天只有 Spaces(#501):依 workspace 分段,每個 Tab 一列,列念出標題、種類與狀態。
    @MainActor
    func testLaunchShowsDemoHostAgent() {
        let app = XCUIApplication.launchUITesting()

        let row = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        XCTAssertTrue(row.label.contains("Done"), "列沒有狀態文字:\(row.label)")
        XCTAssertTrue(row.label.contains("Claude"), "列沒有 Agent 種類:\(row.label)")
        let header = app.element("spaces.section.demo/w1")
        XCTAssertTrue(header.exists, "沒有 workspace 段落標題")
        XCTAssertTrue(header.label.contains("ledger"), "段落標題沒有 workspace 名稱:\(header.label)")
        XCTAssertTrue(header.label.contains("Demo"), "段落標題沒有主機名:\(header.label)")
    }

    /// 「需要你」以文字(不只顏色)說明狀態;每列先念標題,再念種類與狀態。
    @MainActor
    func testRowsHaveTextualStatus() {
        let app = XCUIApplication.launchUITesting()

        let needsYou = row("w2:p1", in: app)
        let working = row("w3:p1", in: app)
        XCTAssertTrue(needsYou.waitUntilExists(timeout: 10))
        XCTAssertTrue(needsYou.label.contains("Needs You"), "沒有「需要你」文字:\(needsYou.label)")
        XCTAssertTrue(app.reveal(working))
        XCTAssertTrue(working.label.contains("Codex"), "列沒有念出 agent 種類:\(working.label)")
        XCTAssertTrue(working.label.contains("Working"), "工作中的列沒有狀態文字:\(working.label)")
        XCTAssertFalse(app.descendants(matching: .any)["agentList.section.needsYou"].exists, "沒有 Agents 檢視的分段標題")
    }

    @MainActor
    func testSearchFiltersTabs() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.reveal(row("w1:p1", in: app)))

        let search = app.chatSearch
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
        search.tap()
        search.typeEnglish("weather")

        XCTAssertTrue(row("w2:p1", in: app).waitUntilExists(timeout: 5))
        XCTAssertTrue(row("w1:p1", in: app).waitUntilGone(timeout: 5), "不符合的列仍在")
        XCTAssertFalse(row("w3:p1", in: app).exists, "不符合的列仍在")

        search.typeEnglish("zzz")
        XCTAssertTrue(app.element("agentList.noMatches").waitUntilExists(timeout: 5), "沒有「無符合結果」的說明")
    }

    /// 聊天列表頂部(#615):系統導覽列。大標題、右側 [電腦圖示｜＋] 與頭像(由左到右),系統搜尋欄;
    /// 往下滑時系統收合大標題,搜尋欄仍可用,回到頂端大標題回來。
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
        XCTAssertTrue(app.chatSearch.exists, "沒有搜尋欄")
        XCTAssertTrue(app.navigationBars.firstMatch.exists, "系統導覽列不見了")

        let list = app.collectionViews.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        XCTAssertTrue(app.chatSearch.waitUntilExists(timeout: 5), "往下滑後搜尋欄不見了")
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
