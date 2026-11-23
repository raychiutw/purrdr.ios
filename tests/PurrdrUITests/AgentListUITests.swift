import XCTest

final class AgentListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func row(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["agent.row.demo/\(paneID)"].firstMatch
    }

    /// tracer bullet:app → 畫面 model → herdr client → 主機通道(Demo 主機)整條路徑都走正式程式。
    @MainActor
    func testLaunchShowsDemoHostAgent() {
        let app = XCUIApplication.launchUITesting()

        let row = row("w1:p1", in: app)
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        // Agents 列第一行是 workspace 名稱(#269,原型 B)。
        XCTAssertTrue(row.label.contains("ledger"), "列沒有 workspace 名稱:\(row.label)")
        XCTAssertFalse(row.label.contains("Tidy up the CSV export"), "列第一行不該是聊天標題:\(row.label)")
        XCTAssertTrue(row.label.contains("Done"), "列沒有狀態文字:\(row.label)")
    }

    /// 「需要你」在最上面，並以文字(不只顏色)說明在等輸入;工作中的列右欄是「Now」。
    @MainActor
    func testNeedsYouComesFirstWithTextualStatus() {
        let app = XCUIApplication.launchUITesting()

        let needsYou = row("w2:p1", in: app)
        let working = row("w3:p1", in: app)
        let done = row("w1:p1", in: app)
        XCTAssertTrue(needsYou.waitUntilExists(timeout: 10))
        XCTAssertTrue(needsYou.label.contains("Needs You"), "沒有「需要你」文字:\(needsYou.label)")
        XCTAssertTrue(needsYou.label.contains("Waiting for your input"), "沒有等待輸入的預覽:\(needsYou.label)")
        XCTAssertTrue(working.label.contains("notes"), "列沒有 workspace 名稱:\(working.label)")
        XCTAssertTrue(working.label.contains("Now"), "工作中的列沒有「Now」:\(working.label)")
        XCTAssertLessThan(needsYou.frame.minY, working.frame.minY)
        // ledger 在 notes 下方，可能在畫面外(列表是 lazy)。
        XCTAssertTrue(app.reveal(done))
        XCTAssertLessThan(working.frame.minY, done.frame.minY)
    }

    /// Agents 檢視是單一清單(#244):沒有分段標題，需要你仍在工作中之前;每列先念 agent 種類，再念狀態，預覽前是主機名。
    @MainActor
    func testAgentsViewIsSingleListWithHostPreview() {
        let app = XCUIApplication.launchUITesting()
        app.switchListMode(to: "Agents")

        let needsYou = row("w2:p1", in: app)
        let working = row("w3:p1", in: app)
        XCTAssertTrue(needsYou.waitUntilExists(timeout: 10))
        XCTAssertTrue(working.waitUntilExists(timeout: 5))
        XCTAssertTrue(needsYou.label.contains("Needs You"), "狀態點沒有念出狀態:\(needsYou.label)")
        XCTAssertTrue(needsYou.label.contains("Demo · "), "預覽前沒有主機名:\(needsYou.label)")
        XCTAssertTrue(working.label.contains("Now"), "工作中的列沒有「Now」:\(working.label)")
        XCTAssertTrue(working.label.hasPrefix("Codex"), "列首頭像沒有念出 agent 種類:\(working.label)")
        XCTAssertLessThan(needsYou.frame.minY, working.frame.minY)
        XCTAssertFalse(app.descendants(matching: .any)["agentList.section.needsYou"].exists, "單一清單不該有分段標題")
    }

    @MainActor
    func testSearchFiltersAgents() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.reveal(row("w1:p1", in: app)))

        let search = app.chatSearch
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
        search.tap()
        search.typeEnglish("weather")

        XCTAssertTrue(row("w2:p1", in: app).waitUntilExists(timeout: 5))
        XCTAssertFalse(row("w1:p1", in: app).exists, "不符合的列仍在")
        XCTAssertFalse(row("w3:p1", in: app).exists, "不符合的列仍在")

        search.typeEnglish("zzz")
        XCTAssertTrue(app.element("agentList.noMatches").waitUntilExists(timeout: 5), "沒有「無符合結果」的說明")
    }

    /// 聊天列表頂部(#499):共用頂列。左側大標題,右側 [電腦圖示｜＋] 與頭像(由左到右),搜尋欄在標題列下方;
    /// 往下滑時標題列收起、搜尋欄仍可用並貼近頂端,回到頂端標題列回來。
    @MainActor
    func testChatListTopBarCollapsesOnScroll() {
        let app = XCUIApplication.launchUITesting(flags: ["-demoCompanions"])
        XCTAssertTrue(app.reveal(row("w1:p1", in: app)))
        let title = app.staticTexts["topBar.title"]
        XCTAssertTrue(title.waitUntilExists(timeout: 5), "沒有大標題")
        let host = app.buttons["toolbar.currentHost"].firstMatch
        let newChat = app.buttons["toolbar.newChat"].firstMatch
        let account = app.buttons["toolbar.account"].firstMatch
        XCTAssertTrue(host.exists && newChat.exists && account.exists, "頂列缺控制項")
        XCTAssertLessThan(title.frame.minX, host.frame.minX, "標題不在電腦圖示左邊")
        XCTAssertLessThan(host.frame.minX, newChat.frame.minX, "電腦圖示不在＋左邊")
        XCTAssertLessThan(newChat.frame.minX, account.frame.minX, "＋不在頭像左邊")
        let search = app.chatSearch
        XCTAssertTrue(search.exists, "沒有搜尋欄")
        XCTAssertGreaterThan(search.frame.minY, title.frame.maxY - 1, "搜尋欄不在標題下方")
        let topY = search.frame.minY

        let list = app.collectionViews.matching(NSPredicate(format: "identifier != %@", "sidebar")).firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        XCTAssertTrue(title.waitUntilGone(timeout: 5), "往下滑後標題列沒有收起")
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "往下滑後搜尋欄不見了")
        XCTAssertLessThan(search.frame.minY, topY, "搜尋欄沒有上移貼頂")

        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(title.waitUntilExists(timeout: 5), "回到頂端後標題列沒有回來")
    }

    /// AX 字級下 5 個 tab 都在 tab bar 上,帳號與新增聊天仍可從工具列(或溢出選單)點到。
    @MainActor
    func testTabBarAndAccountReachableAtAccessibilitySize() {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.listModeControl.waitUntilExists(timeout: 15))
        for tab in [AppTab.chats, .files, .hosts, .traffic, .settings] {
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

    /// 右上角的帳號圓圈跟新增聊天的玻璃鈕看起來一樣大(實機回報 2026-11-20):工具列玻璃鈕畫出來 44pt(XCUI 的 frame 只報內容 36pt)。
    @MainActor
    func testAccountButtonMatchesMoreButton() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"].firstMatch
        XCTAssertTrue(account.waitUntilExists(timeout: 10))
        XCTAssertEqual(account.frame.height, 44, accuracy: 1, "帳號圓圈 \(account.frame) 應與玻璃鈕一樣 44pt")
    }
}
