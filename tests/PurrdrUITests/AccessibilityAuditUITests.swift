import XCTest

/// 無障礙總稽核(#35):以 Demo 主機逐一打開主要畫面，跑 Xcode 的 accessibility audit(`performAccessibilityAudit`)。
///
/// 預設字級跑全部稽核類型;AX5(`AccessibilityXXXL`)再跑一次，看 Dynamic Type 與文字截斷。
/// 確定是系統元件造成或屬於誤報的問題，在 `AccessibilityAuditExclusions` 逐筆寫明理由後排除;其餘一律算失敗。
/// iPad 的稽核在 `IPadLayoutUITests`。
final class AccessibilityAuditUITests: XCTestCase {
    static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 等這些元素的位置連續兩次取樣都不變(動畫、捲動停下)。
    @MainActor
    private func waitForSettledLayout(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = elements.map(\.frame)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let current = elements.map(\.frame)
            if current == previous { return true }
            previous = current
        }
        return false
    }

    // MARK: - Agent 列表

    @MainActor
    func testAgentListSpaces() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            app.switchListMode(to: "Spaces")
            XCTAssertTrue(app.reveal(element("spaces.section.demo/w3", in: app)))
            try audit(app, "Agent 列表(Spaces)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testAgentListAgents() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            XCTAssertTrue(element("agent.row.demo/w2:p1", in: app).waitForExistence(timeout: 15))
            try audit(app, "Agent 列表(Agents)", contentSize: size)
            app.terminate()
        }
    }

    /// 沒有主機的空狀態(#332)。
    @MainActor
    func testAgentListNoHosts() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"], contentSize: size)
            XCTAssertTrue(element("agentList.addHost", in: app).waitForExistence(timeout: 15))
            try audit(app, "Agent 列表(沒有主機)", contentSize: size)
            app.terminate()
        }
    }

    /// 版面圖(Spaces 檢視點有多個 pane 的 Tab,#275)。
    @MainActor
    func testLayout() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            app.switchListMode(to: "Spaces")
            let tab = element("spaces.tab.demo/w3:t1", in: app)
            XCTAssertTrue(app.reveal(tab))
            tab.tap()
            XCTAssertTrue(app.buttons["layout.block.w3:p2"].waitForExistence(timeout: 5))
            try audit(app, "版面圖", contentSize: size)
            app.terminate()
        }
    }

    // MARK: - 對話

    @MainActor
    private func openChat(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        let row = element("agent.row.demo/\(paneID)", in: app)
        XCTAssertTrue(app.reveal(row), "列表上沒有 \(paneID)")
        row.tap()
        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        return text
    }

    @MainActor
    func testConversationNeedsYou() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w2:p1", in: app)
            XCTAssertTrue(element("prompt.card", in: app).waitForExistence(timeout: 15))
            try audit(app, "對話(需要你、subagent)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testConversationWithNoteCard() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w1:p1", in: app)
            XCTAssertTrue(element("youShouldKnow.note", in: app).waitForExistence(timeout: 15))
            try audit(app, "對話(You should know 卡片)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testConversationWorking() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w3:p1", in: app)
            let stop = element("stopBar.stop", in: app)
            XCTAssertTrue(stop.waitForExistence(timeout: 15))
            // 停止列出現時輸入卡片長高、對話跟著捲動：等版面停下再稽核。
            XCTAssertTrue(waitForSettledLayout([stop, element("conversation.working", in: app)], timeout: 5), "版面沒有停下")
            try audit(app, "對話(工作中)", contentSize: size)
            // 工作中指示在輸入卡片正上方的漸層帶：不論 audit 有沒有回報，都以截圖量實際對比(#220)。
            let workingLabel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Writing'")).firstMatch
            XCTAssertTrue(workingLabel.exists, "沒有工作中指示")
            let contrast = measuredTextContrast(workingLabel) ?? 0
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "工作中指示的實際對比只有 \(contrast)")

            // 強制結束的確認對話框(#220)。
            stop.press(forDuration: 1.0)
            let menuItem = app.buttons["Force Quit…"]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "長按沒有強制結束的選項")
            menuItem.tap()
            let confirm = app.buttons["stopBar.forceQuit.confirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "沒有強制結束的確認對話框")
            XCTAssertTrue(waitForSettledLayout([confirm], timeout: 5), "確認對話框沒有停下")
            try audit(app, "強制結束確認", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testSlashMenuAndPanels() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            let text = openChat("w1:p1", in: app)
            text.tap()
            text.typeEnglish("/")
            XCTAssertTrue(element("slash.row.demo-kit:changelog", in: app).waitForExistence(timeout: 10))
            // 選單出現時輸入列上方的元素還在收合、玻璃在淡入：等版面停下再稽核(#249:量到的是動畫中被蓋住一半的加入圖片鈕)。
            let menu = element("slash.menu", in: app)
            XCTAssertTrue(waitForSettledLayout([menu, element("composer.attach", in: app), text], timeout: 5), "版面沒有停下")
            try audit(app, "slash 選單", contentSize: size)
            text.typeEnglish("model")
            element("slash.row.model", in: app).tap()
            element("composer.send", in: app).tap()
            let panel = element("panel.card", in: app)
            XCTAssertTrue(panel.waitForExistence(timeout: 10))
            // 送出就收起鍵盤(#329);還聚焦才點。
            let hide = element("composer.hideKeyboard", in: app)
            if hide.waitForExistence(timeout: 1) { hide.tap() }
            // 收起鍵盤後對話還在捲回最新一列：等版面停下再稽核(#251:AX5 量到捲動中的舊位置，截圖是另一塊)。
            XCTAssertTrue(waitForSettledLayout([panel, element("composer.text", in: app)], timeout: 5), "版面沒有停下")
            try audit(app, "/model 面板卡片", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testShellCommand() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            let text = openChat("w1:p1", in: app)
            text.tap()
            text.typeEnglish("!git status")
            element("composer.send", in: app).tap()
            XCTAssertTrue(element("conversation.shell", in: app).waitForExistence(timeout: 15))
            // 送出就收起鍵盤(#329);還聚焦才點。
            let hide = element("composer.hideKeyboard", in: app)
            if hide.waitForExistence(timeout: 1) { hide.tap() }
            try audit(app, "! 指令", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testTerminal() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w1:p1", in: app)
            let open = app.buttons["terminal.open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.tap()
            XCTAssertTrue(element("terminal.screen", in: app).waitForExistence(timeout: 10))
            try audit(app, "終端機", contentSize: size)
            app.terminate()
        }
    }

    // MARK: - Sheet

    @MainActor
    private func openMenu(_ item: String, in app: XCUIApplication) {
        app.tapToolbarItem("toolbar.more", overflowLabel: "More")
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor
    func testHostsEditorAndShare() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-seedHost"], contentSize: size)
            openMenu("menu.hosts", in: app)
            let row = app.buttons["hosts.row.5EED0000-0000-4000-8000-000000000001"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            try audit(app, "主機清單", contentSize: size)

            row.press(forDuration: 1)
            app.buttons["Share…"].firstMatch.tap()
            XCTAssertTrue(element("hostShare.qr", in: app).waitForExistence(timeout: 5))
            try audit(app, "分享主機", contentSize: size)
            // 返回鈕:AX5 時系統只留箭頭，不以標題找。
            app.navigationBars["Share Host"].buttons.firstMatch.tap()

            XCTAssertTrue(app.buttons["hosts.add"].waitForExistence(timeout: 5))
            app.buttons["hosts.add"].tap()
            XCTAssertTrue(app.buttons["guide.option.ssh"].waitForExistence(timeout: 5))
            try audit(app, "新增主機", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testSettings() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.uiTesting(contentSize: size)
            app.launch()
            app.open(URL(string: "purrdr://settings")!)
            XCTAssertTrue(element("sheet.settings", in: app).waitForExistence(timeout: 10))
            try audit(app, "設定", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testPaywall() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            app.openPlusPaywall()
            // AX5 時方案卡在畫面外(List 是 lazy,不在無障礙樹),先等頁面出來再捲到方案卡。
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 15), "沒有開出付費牆")
            XCTAssertTrue(app.reveal(element("plus.plan.com.raychiu.purrdr.plus.monthly", in: app), timeout: 15), "找不到月方案")
            try audit(app, "付費牆", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testSignIn() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            app.openAccount()
            // 沒登入時帳號頁直接是登入頁(#328)。
            XCTAssertTrue(app.buttons["member.signIn.apple"].waitForExistence(timeout: 10))
            try audit(app, "登入", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testWelcome() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"], contentSize: size)
            XCTAssertTrue(element("sheet.welcome", in: app).waitForExistence(timeout: 10))
            try audit(app, "歡迎頁", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testNewChat() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            openMenu("menu.newChat", in: app)
            XCTAssertTrue(element("sheet.newChat", in: app).waitForExistence(timeout: 10))
            try audit(app, "新增對話", contentSize: size)
            app.terminate()
        }
    }
}
