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
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "chat-list-agents"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSearchFiltersAgents() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.reveal(row("w1:p1", in: app)))

        let search = app.textFields["agentList.search"].firstMatch
        XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
        search.tap()
        search.typeEnglish("weather")

        XCTAssertTrue(row("w2:p1", in: app).waitUntilExists(timeout: 5))
        XCTAssertFalse(row("w1:p1", in: app).exists, "不符合的列仍在")
        XCTAssertFalse(row("w3:p1", in: app).exists, "不符合的列仍在")

        search.typeEnglish("zzz")
        XCTAssertTrue(app.staticTexts["No Matching Agents"].waitUntilExists(timeout: 5), "沒有「無符合結果」的說明")
    }

    /// 聊天列表頂部(#268,原型 purrdr-screens 定案版):沒有大標題、沒有標題選單;導覽列下方直接是 Agents／Spaces 切換(#313 攤開成兩列勾選)，
    /// Agents 檢視的搜尋在它下方(Spaces 沒有搜尋);列表上沒有滑動提示與註記卡。
    @MainActor
    func testChatListTopHasNoLargeTitleAndSearchUnderModeControl() {
        let app = XCUIApplication.launchUITesting()
        XCTAssertTrue(app.reveal(row("w1:p1", in: app)))
        XCTAssertFalse(app.staticTexts["agentList.title"].exists, "不該有大標題")
        XCTAssertFalse(app.navigationBars.buttons["Agents"].exists, "導覽列不該有標題(含標題選單)")
        let control = app.listModeControl
        XCTAssertTrue(control.exists)
        let bar = app.navigationBars.firstMatch.frame
        XCTAssertLessThan(control.frame.minY - bar.maxY, 30, "Agents／Spaces 切換不在導覽列正下方:\(control.frame) 導覽列 \(bar)")
        let search = app.textFields["agentList.search"].firstMatch
        XCTAssertTrue(search.exists, "Agents 檢視沒有搜尋欄")
        XCTAssertGreaterThan(search.frame.minY, control.frame.maxY, "搜尋欄不在 Agents／Spaces 切換下方")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "不該有系統搜尋欄(底部工具列)")
        XCTAssertFalse(app.descendants(matching: .any)["agentList.swipeHint"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["youShouldKnow.listRow"].exists)

        app.switchListMode(to: "Spaces")
        XCTAssertTrue(search.waitUntilGone(timeout: 5), "Spaces 檢視不該有搜尋欄")
    }

    /// AX 字級的選單只有一層(#268,使用者實機截圖):帳號併進「⋯」,選單直接列出所有項目，沒有「更多」第二層，
    /// 也沒有 Agents／Spaces 切換。
    @MainActor
    func testMoreMenuIsOneLevelAtAccessibilitySize() {
        let app = XCUIApplication.launchUITesting(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.listModeControl.waitUntilExists(timeout: 15))
        XCTAssertFalse(app.buttons["toolbar.account"].exists, "AX 字級時帳號應併進「⋯」")
        // 工具列只剩主機篩選與「⋯」:系統不會把它們收進溢出選單(溢出選單裡「⋯」會變成「更多 ›」第二層)。
        XCTAssertFalse(app.buttons["OverflowBarButtonItem"].exists, "工具列被收進溢出選單，選單會變成兩層")
        let more = app.buttons["toolbar.more"].firstMatch
        XCTAssertTrue(more.exists, "工具列沒有「⋯」")
        more.tap()
        for item in ["menu.account", "menu.newChat", "menu.hosts", "menu.settings"] {
            XCTAssertTrue(app.buttons[item].firstMatch.waitUntilExists(timeout: 5), "選單沒有直接列出 \(item)")
        }
    }

    /// 右上角的帳號圓圈跟「⋯」看起來一樣大(實機回報 2026-11-20):工具列玻璃鈕畫出來 44pt(XCUI 的 frame 只報內容 36pt)。
    @MainActor
    func testAccountButtonMatchesMoreButton() {
        let app = XCUIApplication.launchUITesting()
        let account = app.buttons["toolbar.account"].firstMatch
        XCTAssertTrue(account.waitUntilExists(timeout: 10))
        XCTAssertEqual(account.frame.height, 44, accuracy: 1, "帳號圓圈 \(account.frame) 應與玻璃鈕一樣 44pt")
    }
}
