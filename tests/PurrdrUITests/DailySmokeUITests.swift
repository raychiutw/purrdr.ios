import XCTest

/// 日常組(#374、spec #367):每條使用者主流程一個煙霧檢查，串成幾條連續操作，每條只啟動一次 app。
/// 目標 5 分鐘內跑完；細節與分支在各功能自己的 UI 類別(完整組)與 model 測試。
/// 每一段以 `step` 標出名稱，失敗時看得出卡在哪一段；`continueAfterFailure = false`,一段失敗就停。
final class DailySmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// 列表 → 聊天(送出、slash、`!` 指令、權限膠囊)→ 變更頁 → 終端機 → 跨聊天「需要你」橫幅(#530)→ 返回後列表置頂段落(#531)。
    /// 帶 `-demoNeedsYouLater`:打開第一個聊天 3 秒後 notes 變成需要你(weather-app 一開始就需要你,不觸發橫幅)。
    @MainActor
    func testListAndChat() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingSimulatedVideo", "-demoNeedsYouLater"])
        let ledger = app.element("spaces.tab.demo/w1:t1")

        step("列表看到 Demo 的 Agent") {
            XCTAssertTrue(app.reveal(ledger), "沒有看到 Demo 主機的 Agent")
            XCTAssertTrue(ledger.label.contains("Done"), "列沒有狀態文字:\(ledger.label)")
            XCTAssertTrue(app.element("spaces.section.demo/w1").exists, "沒有 workspace 段落標題")
        }
        step("搜尋篩選列表") {
            let search = app.revealChatSearch()
            XCTAssertTrue(search.waitUntilExists(timeout: 5), "沒有搜尋欄")
            search.tap()
            search.typeEnglish("weather")
            XCTAssertTrue(app.element("spaces.tab.demo/w2:t1").waitUntilExists(timeout: 5))
            XCTAssertTrue(ledger.waitUntilGone(timeout: 5), "不符合的列仍在")
            search.typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "\n")
            XCTAssertTrue(ledger.waitUntilExists(timeout: 5), "清掉搜尋後列表沒有回來")
            app.cancelSearchIfActive()
        }
        step("Spaces:搜尋 workspace、沒有檢視切換") {
            XCTAssertTrue(app.reveal(app.element("spaces.section.demo/w3")), "Spaces 沒有 workspace 段落")
            let search = app.revealChatSearch()
            XCTAssertTrue(search.waitUntilExists(timeout: 5), "Spaces 檢視沒有搜尋欄")
            search.tap()
            search.typeEnglish("weather")
            XCTAssertTrue(app.element("spaces.section.demo/w2").waitUntilExists(timeout: 5), "搜尋 workspace 名稱找不到 weather-app")
            XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilGone(timeout: 5), "不符合的 workspace 仍在")
            search.typeEnglish("zzz")
            XCTAssertTrue(app.element("agentList.noMatches").waitUntilExists(timeout: 5), "Spaces 搜尋不到時沒有說明")
            let clear = app.buttons["Clear text"].firstMatch
            XCTAssertTrue(clear.waitUntilExists(timeout: 5), "搜尋欄沒有清除鈕")
            clear.tap()
            XCTAssertTrue(app.element("spaces.section.demo/w3").waitUntilExists(timeout: 5), "清掉搜尋後 Spaces 沒有回來")
            app.cancelSearchIfActive()
            // 聊天只有 Spaces(#501):沒有 Agents／Spaces 切換。
            XCTAssertFalse(app.buttons["agentList.mode"].exists, "聊天不該有檢視切換鈕")
        }
        step("打開聊天並送出") {
            XCTAssertTrue(app.reveal(ledger))
            ledger.tap()
            let text = app.element("composer.text")
            XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
            // 輸入列兩態(#512):聚焦與打一句短話都維持一列、沒有模型膠囊;換行才展開。
            XCTAssertFalse(app.element("composer.model").exists, "收合時不該有模型膠囊")
            text.tap()
            text.typeEnglish("Add a header row too?")
            XCTAssertFalse(app.element("composer.model").exists, "聚焦與一行內的字不該展開輸入列")
            app.element("composer.send").tap()
            app.dismissKeyboard()
            let reply = app.descendants(matching: .any).matching(identifier: "conversation.agent")
                .matching(NSPredicate(format: "label CONTAINS 'This is the demo host'")).firstMatch
            XCTAssertTrue(reply.waitUntilExists(timeout: 15), "對話紀錄沒有接上 agent 的回覆")
        }
        step("slash 選單") {
            let text = app.element("composer.text")
            text.tap()
            text.typeEnglish("/")
            XCTAssertTrue(app.element("slash.menu").waitUntilExists(timeout: 10), "打 / 沒有出現選單")
            text.typeEnglish("check")
            let row = app.element("slash.row.demo-kit:check-diff")
            XCTAssertTrue(row.waitUntilExists(timeout: 5))
            row.tap()
            XCTAssertEqual(text.value as? String, "/demo-kit:check-diff ")
        }
        step("`!` 指令") {
            let text = app.element("composer.text")
            text.clearAndType("!ls Sources")
            XCTAssertTrue(app.element("composer.shellHint").waitUntilExists(timeout: 5), "沒有 shell 模式提示")
            app.element("composer.send").tap()
            XCTAssertTrue(app.element("conversation.shell").waitUntilExists(timeout: 15), "對話紀錄沒有接上 shell 區塊")
            app.dismissKeyboard()
        }
        step("附加影片(#474)") {
            // 相簿挑選器在另一個行程;`-uiTestingSimulatedVideo` 讓「影片」直接給一支小影片。
            app.element("composer.attach").tap()
            XCTAssertTrue(app.element("attach.panel").waitUntilExists(timeout: 5), "沒有附加面板")
            let video = app.element("attach.video")
            XCTAssertTrue(video.waitUntilExists(timeout: 5), "附加面板沒有「影片」")
            video.tap()
            XCTAssertTrue(app.element("composer.attachment.0").waitUntilExists(timeout: 20), "挑影片後輸入列沒有附件卡")
            XCTAssertTrue(app.element("composer.videoPreparation").waitUntilGone(timeout: 10), "影片準備中的進度沒有結束")
            app.element("composer.attachment.remove.0").tap()
            XCTAssertTrue(app.element("composer.attachment.0").waitUntilGone(timeout: 5), "移除後附件卡還在")
            app.dismissKeyboard()
        }
        step("用量環與「⋯」→ 權限模式") {
            XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10), "沒有聊天頂列")
            app.buttons["conversation.usage"].firstMatch.tap()
            XCTAssertTrue(app.element("conversation.panel").waitUntilExists(timeout: 5), "點用量環沒有開出面板")
            XCTAssertTrue(app.element("usage.sheet.context").waitUntilExists(timeout: 5), "面板沒有 Context 卡片")
            app.buttons["panel.close"].tap()
            XCTAssertTrue(app.element("conversation.panel").waitUntilGone(timeout: 5), "面板沒有關閉")
            app.conversationMoreItem("menu.permissionMode").tap()
            XCTAssertTrue(app.element("menu.sheet.permissionMode").waitUntilExists(timeout: 5), "「⋯」→ 權限模式沒有開出 sheet")
            let accept = app.buttons["Accept Edits"].firstMatch
            XCTAssertTrue(accept.waitUntilExists(timeout: 10), "sheet 裡沒有 Accept Edits")
            accept.tap()
            XCTAssertTrue(app.element("menu.sheet.permissionMode").waitUntilGone(timeout: 15), "切換成功後 sheet 沒有自動關閉")
            XCTAssertTrue(app.conversationMoreItem("menu.permissionMode").label.contains("Accept Edits"), "「⋯」的權限模式副標沒有顯示 Accept Edits")
            // 收起「⋯」選單,下一步才能重新打開。
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        step("模型選擇 sheet 與投入程度子頁(#384)") {
            // 輸入列收合時沒有模型膠囊:從「⋯」→ 模型與思考深度開同一張 sheet(#515)。
            app.conversationMoreItem("menu.model").tap()
            XCTAssertTrue(app.element("model.picker").waitUntilExists(timeout: 15), "sheet 裡沒有模型勾選列")
            let effortRow = app.element("model.effort")
            XCTAssertTrue(effortRow.waitUntilExists(timeout: 10), "sheet 裡沒有投入程度列")
            effortRow.tap()
            XCTAssertTrue(app.element("effort.picker").waitUntilExists(timeout: 15), "子頁沒有層級勾選列")
            XCTAssertTrue(app.element("effort.ultracode").waitUntilExists(timeout: 5), "子頁沒有 Ultracode 開關")
            let high = app.buttons.matching(NSPredicate(format: "label CONTAINS 'High' AND NOT label CONTAINS 'Extra'")).firstMatch
            XCTAssertTrue(high.waitUntilExists(timeout: 5), "子頁沒有 High 層級")
            high.tap()
            XCTAssertTrue(high.wait(for: NSPredicate(format: "isSelected == true"), timeout: 10), "點層級沒有打勾")
            // 返回確認投入程度並回到模型列。
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.element("model.picker").waitUntilExists(timeout: 15), "返回後沒有回到模型列")
            app.element("model.close").tap()
            XCTAssertTrue(app.element("model.picker").waitUntilGone(timeout: 5), "xmark 沒有關閉 sheet")
            app.dismissKeyboard()
        }
        step("變更頁") {
            app.conversationMoreItem("changes.open").tap()
            let summary = app.descendants(matching: .any)["changes.summary"].firstMatch
            XCTAssertTrue(summary.waitUntilExists(timeout: 10), "沒有變更清單")
            back(app)
        }
        step("終端機") {
            app.conversationMoreItem("terminal.open").tap()
            XCTAssertTrue(app.descendants(matching: .any)["terminal.screen"].firstMatch.waitUntilExists(timeout: 10), "沒有打開終端機")
            back(app)
        }
        step("別的聊天變成需要你:橫幅出現,點了開 notes 的聊天") {
            let open = app.buttons["needsYou.banner.open"]
            XCTAssertTrue(open.waitUntilExists(timeout: 20), "別的聊天變成需要你後沒有橫幅")
            XCTAssertTrue(open.label.hasPrefix("notes"), "橫幅沒有寫出 notes:\(open.label)")
            open.tap()
            let subtitle = app.conversationSubtitle(containing: "Needs You")
            XCTAssertTrue(subtitle.waitUntilExists(timeout: 10), "點橫幅後沒有換成需要你的 notes 聊天(標題在這條流程裡是 Tab 名稱,看副標題的狀態)")
            XCTAssertTrue(app.element("needsYou.banner").waitUntilGone(timeout: 5), "已經在那個聊天,橫幅該消失")
        }
        step("返回後列表最上面有「需要你」段落") {
            back(app)
            let section = app.element("needsYou.section")
            XCTAssertTrue(section.waitUntilExists(timeout: 10), "返回後列表沒有「需要你」段落")
            XCTAssertTrue(section.wait(for: NSPredicate(format: "label CONTAINS '2 chats need you'"), timeout: 10), "段落沒有列出 weather-app 與 notes:\(section.label)")
            XCTAssertTrue(app.element("needsYou.tab.demo/w3:t1").waitUntilExists(timeout: 5), "段落裡沒有 notes")
        }
    }

    /// 「需要你」的聊天:subagent 卡、回答 Bash 權限。
    @MainActor
    func testNeedsYouAndSubagent() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w2:p1")

        step("subagent 卡展開") {
            XCTAssertTrue(app.staticTexts["Check how the widget refreshes"].waitUntilExists(timeout: 10), "沒有 subagent 卡")
            app.element("conversation.subagent").tap()
            XCTAssertTrue(app.element("conversation.subagent.result").waitUntilExists(timeout: 5), "點卡片沒有展開結果")
        }
        step("回答 Bash 權限") {
            let card = app.element("prompt.card")
            XCTAssertTrue(card.waitUntilExists(timeout: 10), "沒有提示卡")
            app.element("prompt.option.1").tap()
            XCTAssertTrue(app.element("prompt.answered").waitUntilExists(timeout: 10), "沒有顯示已回答")
        }
    }

    /// 5 個 tab(#390):設定、主機、檔案、流量各自是 tab;新增聊天在聊天 tab 右上;帳號(未登入是登入頁)四個以上的 tab 都有;
    /// 沒有「⋯」選單;對話隱藏 tab bar、返回後回來。
    @MainActor
    func testTabsAndSignedOutAccount() {
        // `-uiTestingNoMember`:沒登入,Apple／Google 按鈕直接登入假後台;登入頁查無會員(404 member_not_found),加入頁照舊新建(#453)。
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoMember"])

        step("沒有「⋯」選單,右上依 tab 不同") {
            XCTAssertTrue(app.buttons["toolbar.newChat"].firstMatch.waitUntilExists(timeout: 10), "聊天 tab 沒有新增聊天")
            XCTAssertFalse(app.buttons["toolbar.more"].exists, "不該再有「⋯」選單")
            app.openTab(.files)
            XCTAssertTrue(app.buttons["files.upload"].firstMatch.waitUntilExists(timeout: 10), "檔案 tab 沒有上傳")
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "檔案 tab 沒有帳號鈕")
            XCTAssertFalse(app.buttons["toolbar.newChat"].exists, "檔案 tab 不該有新增聊天")
            // 資料夾是 push(#620):進一層、tab bar 還在、左上「<」回第一層。
            let ledger = app.buttons["files.row.ledger"].firstMatch
            XCTAssertTrue(ledger.waitUntilExists(timeout: 10), "檔案 tab 沒有列出家目錄")
            ledger.tap()
            XCTAssertTrue(app.navigationBars["ledger"].waitUntilExists(timeout: 10), "沒有推進下一層")
            XCTAssertTrue(app.tabBars.firstMatch.exists, "下一層沒有保留 tab bar")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitUntilExists(timeout: 10), "返回沒有回到第一層")
            app.openHostsTab()
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "主機 tab 沒有帳號鈕")
            // 沒有已存主機時主機 tab 是範例主機:只有範例狀態、登入 Shell 與「移除範例主機」(#392、#434)。
            XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 10), "主機 tab 沒有連線狀態")
            XCTAssertTrue(app.buttons["hosts.demo.remove"].exists, "範例主機沒有「移除範例主機」")
            // 刻意偏離設計稿(#434):範例主機保留「登入 Shell」,App Review 用它開 Demo 的模擬終端機。
            XCTAssertTrue(app.overviewRow("hosts.tool.loginShell").exists, "範例主機沒有保留登入 Shell")
            app.openTab(.traffic)
            XCTAssertTrue(app.element("dataUsage.page").waitUntilExists(timeout: 10), "流量 tab 沒有網路流量頁")
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "流量 tab 沒有帳號鈕")
            XCTAssertFalse(app.buttons["hosts.add"].exists, "流量 tab 右上不放動作")
        }
        step("設定併在帳號 sheet,只有四個 tab,右上 X 關閉(#503)") {
            XCTAssertFalse(app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings")).firstMatch.exists, "不該再有設定 tab")
            app.openSettingsSheet()
            let used = app.buttons["Used"].firstMatch
            XCTAssertTrue(app.scrollIntoView(used, search: .down) || used.exists, "帳號與設定沒有用量顯示的「已用」(#389)")
            app.closeAccountSheet()
            XCTAssertTrue(app.buttons["toolbar.account"].firstMatch.exists, "關閉後沒有回到 tab")
        }
        step("新增聊天") {
            app.openNewChatSheet()
            XCTAssertTrue(app.element("sheet.newChat").waitUntilExists(timeout: 10), "沒有開出新增聊天")
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(app.element("sheet.newChat").waitUntilGone(timeout: 5), "新增聊天沒有關閉")
        }
        step("對話隱藏 tab bar,返回後回來") {
            app.openConversation(paneID: "w1:p1")
            XCTAssertTrue(app.tabBars.firstMatch.waitUntilGone(timeout: 5), "對話裡不該有 tab bar")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 5), "返回後 tab bar 沒有回來")
        }
        step("未登入的帳號頁先選登入或加入會員") {
            app.openAccount()
            XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "沒登入沒有顯示選擇頁")
            XCTAssertTrue(app.buttons["account.entry.signIn"].exists, "沒有「登入」")
            XCTAssertTrue(app.buttons["account.entry.join"].exists, "沒有「加入會員」")
            XCTAssertFalse(app.buttons["member.signIn.apple"].exists, "選擇前不該先看到 Apple 登入鈕")
            // 帳號與設定是滿版 modal(#623):蓋住 tab bar,左上 X。
            XCTAssertFalse(app.tabBars.firstMatch.isHittable, "帳號與設定沒有蓋滿畫面")
            app.assertModalToolbar(close: "member.signIn.cancel")
        }
        step("列尾 > 推入登入頁,系統返回第一下就回到選擇頁") {
            app.buttons["account.entry.signIn"].tap()
            XCTAssertTrue(app.element("account.entry.signInPage").waitUntilExists(timeout: 5), "沒有推入登入頁")
            app.navigationBars.buttons["Account"].tap()
            XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 5), "第一下返回沒有回到選擇頁")
        }
        step("登入頁查無會員:擋下並問要不要加入,確認才進加入流程") {
            app.buttons["account.entry.signIn"].tap()
            XCTAssertTrue(app.buttons["member.signIn.apple"].waitUntilExists(timeout: 5), "沒有登入頁")
            app.buttons["member.signIn.apple"].tap()

            XCTAssertTrue(app.alerts["No Member Found"].waitUntilExists(timeout: 10), "查無會員沒有擋下並詢問")
            XCTAssertFalse(app.element("account.join.paywall").exists, "查無會員不該直接進加入流程")
            app.alerts["No Member Found"].buttons["member.notFound.join"].firstMatch.tap()
        }
        step("加入會員:略過 Plus,通知鎖定,完成頁是會員已建立") {
            // 上一步按了「加入」已在加入第 1 步(不再回選擇頁)。
            XCTAssertTrue(app.buttons["member.signIn.apple"].waitUntilExists(timeout: 5), "加入第 1 步沒有 Apple 註冊鈕")
            XCTAssertEqual(app.staticTexts["member.entry.step"].label, "Step 1 of 4")
            XCTAssertTrue(app.navigationBars.buttons["Account"].exists, "第 1 步左上應是系統返回")
            app.buttons["member.signIn.apple"].tap()

            XCTAssertTrue(app.element("account.join.paywall").waitUntilExists(timeout: 10), "建立會員後沒有進開通 Plus")
            XCTAssertEqual(app.staticTexts["member.entry.step"].label, "Step 2 of 4")
            XCTAssertFalse(app.navigationBars.buttons["Account"].exists, "第 2 步起左上不是返回")
            XCTAssertTrue(app.buttons["member.signIn.cancel"].exists, "第 2 步起左上應是關閉")
            app.buttons["account.join.secondary"].tap()

            XCTAssertTrue(app.element("account.join.notificationsLocked").waitUntilExists(timeout: 5), "略過 Plus 後通知沒有鎖定")
            XCTAssertEqual(app.staticTexts["member.entry.step"].label, "Step 3 of 4")
            XCTAssertTrue(app.buttons["account.join.primary"].label.contains("Activate Purrdr Plus"))
            app.buttons["account.join.secondary"].tap()

            XCTAssertTrue(app.element("account.join.doneCreated").waitUntilExists(timeout: 5), "略過 Plus 的完成頁不是「會員已建立」")
            app.buttons["account.join.primary"].tap()
            XCTAssertTrue(app.element("sheet.account").waitUntilExists(timeout: 10), "開始使用後沒有回到帳號頁")
        }
        step("以左上 X 關閉帳號與設定,回到 tab bar") {
            app.assertModalToolbar(close: "member.close")
            app.closeAccountSheet()
            XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 5), "關閉後 tab bar 沒有回來")
        }
    }

    /// 兩個主機值(#390):在檔案 tab 換「選取中主機」不改聊天 tab 的「目前主機」篩選。
    @MainActor
    func testFilesHostMenuDoesNotChangeChatFilter() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnreachableHost"])
        app.filterHosts("Studio Mac")
        XCTAssertEqual(app.buttons["toolbar.currentHost"].firstMatch.label, "Showing: Studio Mac")

        app.openTab(.files)
        let picker = app.buttons["files.host"].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "檔案 tab 沒有主機選單")
        picker.tap()
        XCTAssertFalse(app.buttons["All Hosts"].exists, "檔案 tab 的主機選單不該列所有主機")
        XCTAssertTrue(app.buttons["hostMenu.addHost"].firstMatch.exists, "主機選單沒有新增主機…")
        app.buttons["Build Box"].firstMatch.tap()
        XCTAssertTrue(app.buttons["files.host"].firstMatch.waitForLabel(containing: "Build Box", timeout: 5))

        app.openTab(.chats)
        XCTAssertEqual(app.buttons["toolbar.currentHost"].firstMatch.label, "Showing: Studio Mac", "換選取中主機不該改聊天的目前主機")
    }

    /// 聊天 tab 的 badge 是「需要你」的 Agent 數。
    @MainActor
    func testChatsTabBadgeCountsNeedsYou() {
        let app = XCUIApplication.launchUITesting()
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chats")).firstMatch
        XCTAssertTrue(tab.waitUntilExists(timeout: 10))
        // badge 可能念在標籤尾端,也可能是元素的 value。
        let shows = UITestWait.until(timeout: 15) { tab.exists && (tab.label.contains("1") || (tab.value as? String)?.contains("1") == true) }
        XCTAssertTrue(shows, "聊天 tab 沒有標示 1 個需要你:\(tab.label) / \(String(describing: tab.value))")
    }

    /// Purrdr Plus 會員：帳號頁、通知、通知裝置。
    @MainActor
    func testPlusMemberAccount() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedHost"])
        step("主機 tab 的通知有 Plus 時不鎖定,可進入開關頁") {
            app.openHostsTab()
            let row = app.overviewRow("hosts.notifications")
            XCTAssertTrue(row.exists, "有 Plus 時主機 tab 沒有可進入的通知")
            XCTAssertFalse(app.buttons["hosts.tool.notifications.locked"].exists, "有 Plus 不該鎖定通知")
            row.tap()
            XCTAssertTrue(app.element("hosts.notifications.page").waitUntilExists(timeout: 10), "沒有進到通知開關頁")
        }
        step("帳號頁與通知裝置") {
            back(app)
            // 返回後頁面仍捲在下面,頂列已收合(標題列與頭像淡出、不能點):捲回頂端才點得到帳號鈕。
            let account = app.buttons["toolbar.account"].firstMatch
            for _ in 0..<5 where !account.isHittable { app.element("sheet.hosts").swipeDown() }
            XCTAssertTrue(account.isHittable, "回到主機總頁後頂列沒有展開")
            app.openAccountSheet()
            let card = app.element("account.plusCard.status")
            XCTAssertTrue(card.waitUntilExists(timeout: 10), "帳號頁沒有 Plus 卡")
            XCTAssertTrue(card.label.contains("Active"), "有 Plus 的卡不是已開通:\(card.label)")
            let link = app.element("member.pushDevices")
            XCTAssertTrue(app.scrollSheet("sheet.account", to: link, search: .down, timeout: 10), "帳號頁沒有通知裝置入口")
            link.tap()
            let device = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'account.pushDevice.' AND label CONTAINS 'Studio iPad'")).firstMatch
            XCTAssertTrue(device.waitUntilExists(timeout: 10), "通知裝置子頁沒有 Studio iPad")
        }
    }

    /// 數據用量。
    @MainActor
    func testDataUsage() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedDataUsage"])
        step("主機 tab 總頁:狀態、用量區、這台主機的入口(#392)") {
            app.openHostsTab()
            XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 10), "沒有連線狀態")
            XCTAssertTrue(app.element("usage.enable.claudeCode").waitUntilExists(timeout: 10), "主機 tab 的用量區沒有「啟用用量顯示」(#389)")
            XCTAssertTrue(app.element("usage.row.codex.fiveHour").waitUntilExists(timeout: 10), "主機 tab 的用量區沒有 Codex 5 小時")
            // 沒登入就沒有 Plus(#405):通知鎖定並寫出原因,不是可開關的列。
            let locked = app.overviewRow("hosts.tool.notifications.locked")
            XCTAssertTrue(locked.exists, "沒有 Plus 時主機 tab 的通知沒有鎖定")
            XCTAssertTrue((locked.value as? String)?.contains("Needs Purrdr Plus") == true, "鎖定的通知沒有說明需要 Purrdr Plus:\(String(describing: locked.value))")
            XCTAssertFalse(app.buttons["hosts.notifications"].exists, "沒有 Plus 不該能進通知開關")
            XCTAssertTrue(app.overviewRow("hosts.tool.loginShell").exists, "總頁沒有登入 Shell")
        }
        step("主機的 Agent 設定:關掉 Codex 後用量區不再列、新增聊天不再出現 Codex(#477)") {
            let row = app.overviewRow("hosts.agents")
            XCTAssertTrue(row.exists, "這台主機沒有「Agent」列")
            row.tap()
            XCTAssertTrue(app.element("hosts.agents.page").waitUntilExists(timeout: 10), "沒有開出 Agent 設定頁")
            let codex = app.switches["hosts.agents.codex"]
            XCTAssertTrue(codex.waitUntilExists(timeout: 5), "Agent 設定頁沒有 Codex 開關")
            XCTAssertEqual(codex.value as? String, "1", "既有主機升級後應預設開啟目前顯示用量的 Codex")
            codex.switches.firstMatch.tap()
            XCTAssertTrue(codex.wait(for: NSPredicate(format: "value == '0'"), timeout: 5), "Codex 開關沒有關掉")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 10), "沒有回到主機總頁\n\(app.debugDescription)")
            XCTAssertTrue(app.element("usage.enable.claudeCode").waitUntilExists(timeout: 10), "Claude 用量被一起關掉了")
            XCTAssertFalse(app.element("usage.row.codex.fiveHour").waitUntilExists(timeout: 2), "關掉 Codex 後用量區還列著它")
        }
        step("數據用量摘要") {
            app.openTab(.traffic)
            XCTAssertTrue(app.element("dataUsage.page").waitUntilExists(timeout: 10), "沒有數據用量頁")
            XCTAssertTrue(app.element("dataUsage.today").waitUntilExists(timeout: 5), "沒有今天的用量")
        }
    }

    /// 沒有主機：空狀態的「新增主機」開引導，取消後體驗範例主機;可從主機 tab 移除,也可從新增主機引導再啟用(#394)。
    @MainActor
    func testNoHostsGuideAndDemo() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingNoHosts"])
        step("空狀態開新增主機引導") {
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 10), "沒有沒有主機的空狀態")
            app.buttons["agentList.addHost"].tap()
            XCTAssertTrue(app.buttons["guide.option.ssh"].waitUntilExists(timeout: 5), "沒有開出新增主機引導")
            app.buttons["guide.cancel"].tapWhenReady()
            // 引導開在主機 tab 裡：取消後回到主機清單，再回聊天 tab 看到空狀態。
            XCTAssertTrue(app.buttons["hosts.add"].waitUntilExists(timeout: 5), "沒有回到主機清單")
            app.openTab(.chats)
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 5), "沒有回到空狀態")
        }
        step("試用 Demo") {
            app.buttons["agentList.tryDemo"].tapWhenReady()
            XCTAssertTrue(app.reveal(app.element("spaces.tab.demo/w1:t1")), "沒有列出 Demo 的 Agent")
        }
        step("移除範例主機回到空狀態") {
            app.openTab(.hosts)
            app.buttons["hosts.demo.remove"].tapWhenReady()
            app.buttons["hosts.demo.remove.confirm"].firstMatch.tapWhenReady()
            XCTAssertTrue(app.element("hosts.noHost").waitUntilExists(timeout: 5), "移除後主機 tab 沒有回到沒有主機的空狀態")
            app.openTab(.chats)
            XCTAssertTrue(app.descendants(matching: .any)["agentList.noHosts"].waitUntilExists(timeout: 5), "移除後沒有回到空狀態")
        }
        step("新增主機引導第一頁可以體驗範例主機") {
            app.openTab(.hosts)
            app.buttons["hosts.add"].tapWhenReady()
            app.buttons["guide.tryDemo"].tapWhenReady()
            XCTAssertTrue(app.reveal(app.element("spaces.tab.demo/w1:t1")), "沒有列出範例主機的 Agent")
        }
    }

    /// 第一次開啟的歡迎頁。
    @MainActor
    func testWelcome() {
        let app = XCUIApplication.launchUITesting(flags: ["-showWelcome"])
        step("歡迎頁試用 Demo") {
            XCTAssertTrue(app.descendants(matching: .any)["sheet.welcome"].waitUntilExists(timeout: 10), "沒有歡迎頁")
            app.buttons["welcome.demo"].tap()
            XCTAssertTrue(app.reveal(app.element("spaces.tab.demo/w1:t1")), "沒有回到列表")
        }
    }
}


extension XCUIApplication {
    /// 搜尋啟用時導覽列換成搜尋欄與取消:取消後才看得到頂列(已經收起就不動)。
    @MainActor
    func cancelSearchIfActive() {
        guard !chatListReady.isHittable else { return }
        let cancel = navigationBars.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close', 'Dismiss'}")).firstMatch
        if cancel.waitUntilExists(timeout: 5) {
            cancel.tap()
        } else {
            print("SEARCH-CANCEL-MISSING", navigationBars.firstMatch.debugDescription)
        }
        _ = chatListReady.waitUntilExists(timeout: 5)
    }
}
