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

    // MARK: - Agent 列表

    @MainActor
    func testAgentListSpaces() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            app.switchListMode(to: "Spaces")
            XCTAssertTrue(app.reveal(app.element("spaces.section.demo/w3")))
            try audit(app, "Agent 列表(Spaces)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testAgentListAgents() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            XCTAssertTrue(app.element("agent.row.demo/w2:p1").waitUntilExists(timeout: 15))
            try audit(app, "Agent 列表(Agents)", contentSize: size)
            app.terminate()
        }
    }

    /// 沒有主機的空狀態(#332)。
    @MainActor
    func testAgentListNoHosts() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"], contentSize: size)
            XCTAssertTrue(app.element("agentList.addHost").waitUntilExists(timeout: 15))
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
            let tab = app.element("spaces.tab.demo/w3:t1")
            XCTAssertTrue(app.reveal(tab))
            tab.tap()
            XCTAssertTrue(app.buttons["layout.block.w3:p2"].waitUntilExists(timeout: 5))
            try audit(app, "版面圖", contentSize: size)
            app.terminate()
        }
    }

    // MARK: - 對話

    @MainActor
    private func openChat(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        app.openConversation(paneID: paneID)
        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        return text
    }

    @MainActor
    func testConversationNeedsYou() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w2:p1", in: app)
            XCTAssertTrue(app.element("prompt.card").waitUntilExists(timeout: 15))
            try audit(app, "對話(需要你、subagent)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testConversationWithNoteCard() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w1:p1", in: app)
            XCTAssertTrue(app.element("youShouldKnow.note").waitUntilExists(timeout: 15))
            try audit(app, "對話(You should know 卡片)", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testConversationWorking() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w3:p1", in: app)
            let stop = app.element("stopBar.stop")
            XCTAssertTrue(stop.waitUntilExists(timeout: 15))
            // 停止列出現時輸入卡片長高、對話跟著捲動：等版面停下再稽核。
            XCTAssertTrue(app.waitForSettledLayout([stop, app.element("conversation.working")], timeout: 5), "版面沒有停下")
            try audit(app, "對話(工作中)", contentSize: size)
            // 工作中指示在輸入卡片正上方的漸層帶：不論 audit 有沒有回報，都以截圖量實際對比(#220)。
            let workingLabel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Writing'")).firstMatch
            XCTAssertTrue(workingLabel.exists, "沒有工作中指示")
            let contrast = measuredTextContrast(workingLabel) ?? 0
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "工作中指示的實際對比只有 \(contrast)")

            // 強制結束的確認對話框(#220)。
            stop.press(forDuration: 1.0)
            let menuItem = app.buttons["Force Quit…"]
            XCTAssertTrue(menuItem.waitUntilExists(timeout: 5), "長按沒有強制結束的選項")
            menuItem.tap()
            let confirm = app.buttons["stopBar.forceQuit.confirm"].firstMatch
            XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "沒有強制結束的確認對話框")
            XCTAssertTrue(app.waitForSettledLayout([confirm], timeout: 5), "確認對話框沒有停下")
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
            XCTAssertTrue(app.element("slash.row.demo-kit:changelog").waitUntilExists(timeout: 10))
            // 選單出現時輸入列上方的元素還在收合、玻璃在淡入：等版面停下再稽核(#249:量到的是動畫中被蓋住一半的加入圖片鈕)。
            let menu = app.element("slash.menu")
            XCTAssertTrue(app.waitForSettledLayout([menu, app.element("composer.attach"), text], timeout: 5), "版面沒有停下")
            try audit(app, "slash 選單", contentSize: size)
            text.typeEnglish("model")
            app.element("slash.row.model").tap()
            app.element("composer.send").tap()
            let panel = app.element("panel.card")
            XCTAssertTrue(panel.waitUntilExists(timeout: 10))
            // 送出就收起鍵盤(#329);還聚焦才點。
            app.dismissKeyboard()
            // 收起鍵盤後對話還在捲回最新一列：等版面停下再稽核(#251:AX5 量到捲動中的舊位置，截圖是另一塊)。
            XCTAssertTrue(app.waitForSettledLayout([panel, app.element("composer.text")], timeout: 5), "版面沒有停下")
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
            app.element("composer.send").tap()
            XCTAssertTrue(app.element("conversation.shell").waitUntilExists(timeout: 15))
            // 送出就收起鍵盤(#329);還聚焦才點。
            app.dismissKeyboard()
            try audit(app, "! 指令", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testTerminal() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            _ = openChat("w1:p1", in: app)
            app.conversationMoreItem("terminal.open").tap()
            XCTAssertTrue(app.element("terminal.screen").waitUntilExists(timeout: 10))
            try audit(app, "終端機", contentSize: size)
            app.terminate()
        }
    }

    // MARK: - Sheet

    @MainActor
    private func openMenu(_ item: String, in app: XCUIApplication) {
        switch item {
        case "menu.hosts": app.openHostsTab()
        case "menu.newChat": app.openNewChatSheet()
        default: XCTFail("沒有這個入口 \(item)")
        }
    }

    @MainActor
    func testHostsEditorAndShare() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-seedHost"], contentSize: size)
            openMenu("menu.hosts", in: app)
            let share = app.overviewRow("hosts.share")
            XCTAssertTrue(share.exists)
            try audit(app, "主機總頁", contentSize: size)

            share.tap()
            XCTAssertTrue(app.element("hostShare.qr").waitUntilExists(timeout: 5))
            try audit(app, "分享主機", contentSize: size)
            // 返回鈕:AX5 時系統只留箭頭，不以標題找。
            app.navigationBars["Share Host"].buttons.firstMatch.tap()

            XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5))
            app.buttons["hosts.add"].tap()
            XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5))
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
            XCTAssertTrue(app.element("sheet.settings").waitUntilExists(timeout: 10))
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
            XCTAssertTrue(app.collectionViews.firstMatch.waitUntilExists(timeout: 15), "沒有開出付費牆")
            XCTAssertTrue(app.reveal(app.element("plus.plan.com.raychiu.purrdr.plus.monthly"), timeout: 15), "找不到月方案")
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
            XCTAssertTrue(app.buttons["member.signIn.apple"].waitUntilExists(timeout: 10))
            try audit(app, "登入", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testWelcome() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"], contentSize: size)
            XCTAssertTrue(app.element("sheet.welcome").waitUntilExists(timeout: 10))
            try audit(app, "歡迎頁", contentSize: size)
            app.terminate()
        }
    }

    @MainActor
    func testNewChat() throws {
        for size in [nil, Self.ax5] {
            let app = XCUIApplication.launchUITesting(contentSize: size)
            openMenu("menu.newChat", in: app)
            XCTAssertTrue(app.element("sheet.newChat").waitUntilExists(timeout: 10))
            try audit(app, "新增對話", contentSize: size)
            app.terminate()
        }
    }
}
