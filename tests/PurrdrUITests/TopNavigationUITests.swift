import XCTest

/// iPhone 頂層導覽(#376、#390):底部 5 個 tab(聊天、檔案、主機、流量、設定),新增聊天在聊天 tab 右上以 sheet 開啟;
/// 設定支援深層連結 `purrdr://settings`(開帳號與設定 sheet,#503)。
final class TopNavigationUITests: XCTestCase {
    private let settingsLink = URL(string: "purrdr://settings")!

    override func setUp() {
        continueAfterFailure = false
    }

    /// 各 tab 頂端的版面規則(#475、#500):大標題的水平與垂直位置、帳號鈕的高度與位置在每個 tab 一致;
    /// 右側控制項(膠囊或單顆圓鈕)的右緣都貼著帳號鈕左邊。只比各 tab 之間的相對關係(容差內相等),不寫死像素。
    ///
    /// 同一次啟動依序(原本 8 個測試合併):聊天列預設字級的列高、開聊天與左緣返回再開、「需要你」段落、各 tab 頂列對齊、
    /// icon-only 按鈕的標籤與點擊範圍、背景中開 `purrdr://settings`、最後點頭像外圍 18pt。
    @MainActor
    func testRowHeightsNeedsYouSectionTopBarsAlignLabelsAndSettingsLink() {
        let app = XCUIApplication.launchUITesting()
        let ledgerID = "spaces.tab.demo/w1:t1"

        // Spaces 的 Tab 列:預設字級時列高不會因為右欄上下堆疊或文字被擠成一字一行而暴增(堆疊只在 AX 字級)。
        let ledger = app.element(ledgerID)
        XCTAssertTrue(app.reveal(ledger), "列表沒有 ledger 列")
        XCTAssertLessThan(ledger.frame.height, 125, "ledger 列太高:\(ledger.frame)")
        let needsYou = app.element("spaces.tab.demo/w2:t1")
        XCTAssertTrue(app.reveal(needsYou))
        XCTAssertLessThan(needsYou.frame.height, 125, "「需要你」列太高:\(needsYou.frame)")

        // 打開聊天、左緣滑動返回、再開一次(不量暫態骨架與位置:時序賽跑,畫面層快取還原由 model 層 `ConversationFastLoadTests` 守)。
        do {
            let row = app.element(chatRowID("w1:p1"))
            XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
            row.tap()
            XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 15), "第一次開啟後沒有出現訊息")
            XCTAssertTrue(app.conversationBar.waitUntilExistsAndSettled(timeout: 15), "沒有開出聊天畫面")

            let composer = app.element("composer.text")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            XCTAssertTrue(composer.waitUntilGone(timeout: 5), "左緣滑動沒有離開聊天(#641)")
            XCTAssertTrue(app.reveal(row), "左緣滑動後沒有回到列表")
            XCTAssertTrue(row.waitUntilHittable(timeout: 5))
            row.tap()
            XCTAssertTrue(app.element("conversation.user").waitUntilExists(timeout: 15), "第二次開啟後沒有出現訊息")
        }

        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 聊天列表最上面的「需要你」段落(#531、spec #528;原 NeedsYouSectionUITests)。
        do {
            let header = app.element("needsYou.section")
            XCTAssertTrue(app.scrollIntoView(header, search: .up, timeout: 15), "沒有「需要你」段落")
            XCTAssertTrue(header.label.contains("1 chat needs you"), "標題沒有數量:\(header.label)")
            let row = app.element("needsYou.tab.demo/w2:t1")
            XCTAssertTrue(row.waitUntilExists(timeout: 5), "段落裡沒有需要你的列")
            XCTAssertTrue(row.label.contains("Needs You"), "列沒有狀態文字:\(row.label)")
            XCTAssertTrue(app.element("spaces.tab.demo/w2:t1").exists, "原本的段落少了這一列")

            row.tap()
            XCTAssertTrue(app.conversationBar.waitUntilExists(timeout: 10), "點段落裡的列沒有開聊天")
            // 標題是 Tab 名稱(不是 workspace 名稱),以副標題的「需要你」狀態確認開到的是 weather-app。
            XCTAssertTrue(app.conversationSubtitle(containing: "Needs You").waitUntilExists(timeout: 10), "開到別的聊天")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.reveal(app.element(ledgerID)), "從「需要你」段落開聊天再返回後沒有回到列表")

        let tabs: [(name: String, open: () -> Void, title: String, control: String)] = [
            ("聊天", { app.openTab(.chats) }, "Chats", "toolbar.newChat"),
            ("檔案", { app.openTab(.files) }, "Files", "files.upload"),
            ("主機", { app.openHostsTab() }, "Hosts", "hosts.add"),
            ("流量", { app.openTab(.traffic) }, "Traffic", "dataUsage.host"),
        ]
        var titleFrames: [(name: String, frame: CGRect)] = []
        var accountFrames: [(name: String, frame: CGRect)] = []
        for tab in tabs {
            tab.open()
            // 聊天列表載入完才量。
            if tab.title == "Chats" { XCTAssertTrue(app.element(chatRowID("w1:p1")).waitUntilExists(timeout: 10)) }
            let title = app.topBarTitle(tab.title)
            XCTAssertTrue(title.waitUntilExists(timeout: 10), "\(tab.name) tab 沒有大標題")
            XCTAssertEqual(title.label, tab.title, "\(tab.name) tab 的大標題不是 tab 名稱")
            let account = app.buttons["toolbar.account"].firstMatch
            XCTAssertTrue(account.waitUntilExists(timeout: 5), "\(tab.name) tab 沒有帳號鈕")
            let control = app.descendants(matching: .any)[tab.control].firstMatch
            XCTAssertTrue(control.waitUntilExists(timeout: 5), "\(tab.name) tab 沒有右側控制項(\(tab.control))")
            XCTAssertLessThan(control.frame.maxX, account.frame.minX, "\(tab.name) tab 的右側控制項和帳號鈕重疊")
            // 帳號圓圈與同列的系統工具列鈕一樣高(#615:都是系統玻璃鈕,不自加尺寸;XCUI 的 frame 只報內容 36pt)。
            if tab.title == "Chats" {
                let newChat = app.buttons["toolbar.newChat"].firstMatch
                XCTAssertEqual(account.frame.height, newChat.frame.height, accuracy: 1, "帳號圓圈 \(account.frame) 與工具列鈕 \(newChat.frame) 不一樣高")
            }
            titleFrames.append((tab.name, title.frame))
            accountFrames.append((tab.name, account.frame))
            print("TOPBAR \(tab.name) title=\(title.frame) account=\(account.frame) control=\(control.frame)")
        }
        // 四個 tab 的大標題位置一致(#615:聊天搜尋欄平常收起,標題與其他 tab 同為大標題)。
        let titleReference = titleFrames[0]
        for entry in titleFrames.dropFirst() {
            XCTAssertEqual(entry.frame.minX, titleReference.frame.minX, accuracy: 2, "\(entry.name) tab 的大標題水平位置和\(titleReference.name)不同")
            XCTAssertEqual(entry.frame.midY, titleReference.frame.midY, accuracy: 2, "\(entry.name) tab 的大標題垂直位置和\(titleReference.name)不同")
        }
        let accountReference = accountFrames[0]
        for entry in accountFrames.dropFirst() {
            XCTAssertEqual(entry.frame.minX, accountReference.frame.minX, accuracy: 2, "\(entry.name) tab 的帳號鈕水平位置和\(accountReference.name)不同")
            XCTAssertEqual(entry.frame.height, accountReference.frame.height, accuracy: 2, "\(entry.name) tab 的帳號鈕高度和\(accountReference.name)不同")
            XCTAssertEqual(entry.frame.midY, accountReference.frame.midY, accuracy: 2, "\(entry.name) tab 的帳號鈕垂直位置和\(accountReference.name)不同")
        }

        // icon-only 按鈕都要有 accessibility label(HIG 檢核清單 20.2);每顆 ≥ 44pt。
        app.openTab(.chats)
        let newChat = app.buttons["toolbar.newChat"].firstMatch
        XCTAssertTrue(newChat.waitUntilExists(timeout: 10), "聊天 tab 沒有新增聊天")
        XCTAssertEqual(newChat.label, "New Chat")
        XCTAssertEqual(app.buttons["toolbar.account"].firstMatch.label, "Account")
        XCTAssertLessThan(newChat.frame.maxX, app.buttons["toolbar.account"].firstMatch.frame.minX, "兩顆右上按鈕重疊")

        // 背景中收到 `purrdr://settings`:開帳號與設定 sheet。
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "app 沒有進背景")
        app.open(settingsLink)
        app.waitForAccountSheet()
        app.closeAccountSheet()

        // 點擊範圍(HIG 44pt):帳號鈕是工具列的 44pt 玻璃圓鈕,XCUI 回報的 frame 只有裡面 30pt 的頭像,
        // 所以改驗行為——點在頭像外 18pt(圓鈕範圍內)也要開得出帳號頁。
        app.buttons["toolbar.account"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 18, dy: 0)).tap()
        XCTAssertTrue(app.element("account.signedOut").waitUntilExists(timeout: 10), "點頭像外圍(44pt 範圍內)沒有開出帳號頁")
    }
}
