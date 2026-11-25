import XCTest

/// 主機 tab 的登入 Shell 與檔案 tab(行為規格 F13):Demo 主機的回顯 shell 與記憶體裡的資料夾。
final class HostToolsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openMenuItem(_ id: String, in app: XCUIApplication) {
        switch id {
        case "menu.files":
            app.openTab(.files)
        case "menu.newChat":
            app.openNewChat()
        default:
            // 登入 Shell 在主機 tab。
            app.openHostsTab()
            let item = app.overviewRow("hosts.tool.loginShell")
            XCTAssertTrue(item.exists, "主機 tab 沒有登入 Shell")
            item.tap()
        }
    }

    /// 上傳失敗的說明顯示在列表上、不彈 alert(#625、#626):`-uiTestingSimulatedFileUpload` 上傳與家目錄已有項目同名的檔案,
    /// Demo 主機回「已有同名項目」;說明可關閉。
    @MainActor
    func testUploadFailureShowsInlineNoticeNotAlert() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingSimulatedFileUpload"])
        openMenuItem("menu.files", in: app)
        let upload = app.buttons["files.upload"].firstMatch
        XCTAssertTrue(upload.waitUntilExists(timeout: 10), "檔案 tab 沒有上傳")
        upload.tap()

        let notice = app.descendants(matching: .any)["files.uploadNotice"].firstMatch
        XCTAssertTrue(notice.waitUntilExists(timeout: 10), "上傳失敗沒有顯示頁內說明")
        XCTAssertTrue(notice.label.contains("README.md"), "說明沒有指出哪個檔案:\(notice.label)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "上傳失敗不該彈 alert")
        notice.buttons["Dismiss"].firstMatch.tap()
        XCTAssertTrue(notice.waitUntilGone(timeout: 5), "說明沒有關掉")
    }

    @MainActor
    func testLoginShellOpensOnSelectedHost() {
        // 已存主機的通道是 Demo 主機,回顯 shell(範例主機自己的入口見 testDemoHostKeepsLoginShell)。
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openMenuItem("menu.loginShell", in: app)

        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        XCTAssertTrue(screen.waitUntilExists(timeout: 10), "沒有打開登入 Shell")
        screen.expectValue(containing: "demo@purrdr ~ %")
        XCTAssertTrue(app.waitForTerminalHeader(containing: "Connected", timeout: 10), "狀態不對:\(app.terminalHeader)")
        XCTAssertTrue(app.terminalHeader.contains("Studio Mac"), "標題不是主機名稱:\(app.terminalHeader)")

        // 鍵盤輸入直接寫進 PTY(Demo 的 shell 會回顯);接上後終端機自動取得焦點。
        app.typeEnglish("ls")
        screen.expectValue(containing: "demo@purrdr ~ % ls")
        XCTAssertTrue(app.buttons["terminal.key.esc"].firstMatch.isHittable, "按鍵列沒有出現")
    }

    /// 檔案頁(#273,原型):資料夾是 push(#620):進兩層、左上「<」返回、麵包屑「~ › ledger」當快速跳層;右上「＋」上傳;沒有「上一層」按鈕。
    @MainActor
    func testFilesBrowseFoldersWithBreadcrumbs() {
        let app = XCUIApplication.launchUITesting()
        openMenuItem("menu.files", in: app)

        let ledger = app.buttons["files.row.ledger"].firstMatch
        XCTAssertTrue(ledger.waitUntilExists(timeout: 10), "沒有列出家目錄")
        XCTAssertTrue(app.descendants(matching: .any)["files.row..zshrc"].firstMatch.exists, "隱藏檔沒有列出")
        XCTAssertEqual(app.topBarTitle("Files").label, "Files", "檔案頁的大標題不是 tab 名稱")
        XCTAssertEqual(app.buttons["files.upload"].firstMatch.label, "Upload File")
        XCTAssertFalse(app.buttons["files.up"].exists, "不該再有「上一層」按鈕")
        XCTAssertEqual(app.buttons["files.crumb.0"].firstMatch.label, "Home Folder")

        // 進兩層(#620):資料夾是 push,左上「<」回上一層,tab bar 保留,大標題是資料夾名稱。
        ledger.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.row.export.csv"].firstMatch.waitUntilExists(timeout: 10), "沒有打開資料夾")
        XCTAssertEqual(app.buttons["files.crumb.1"].firstMatch.label, "ledger")
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).isHittable, "下一層左上沒有返回鈕")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "下一層沒有保留 tab bar")
        XCTAssertTrue(app.navigationBars["ledger"].exists, "下一層的大標題不是資料夾名稱")

        let reports = app.buttons["files.row.reports"].firstMatch
        XCTAssertTrue(reports.waitUntilExists(timeout: 10), "ledger 底下沒有 reports")
        reports.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.empty"].firstMatch.waitUntilExists(timeout: 10), "空資料夾沒有系統空狀態")
        XCTAssertTrue(app.navigationBars["reports"].exists, "第二層的大標題不是資料夾名稱")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["ledger"].waitUntilExists(timeout: 10), "返回沒有回到 ledger")
        XCTAssertTrue(app.descendants(matching: .any)["files.row.export.csv"].firstMatch.exists)

        // 麵包屑當快速跳層:再進 reports,直接點「~」回到第一層。
        app.buttons["files.row.reports"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.empty"].firstMatch.waitUntilExists(timeout: 10))
        app.buttons["files.crumb.0"].firstMatch.tap()
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitUntilExists(timeout: 10), "點「~」沒有回到家目錄")
        XCTAssertEqual(app.topBarTitle("Files").label, "Files")
    }

    // MARK: - 主機挑選鈕(#245)

    @MainActor
    private func pickHost(_ name: String, with pickerID: String, in app: XCUIApplication) {
        let picker = app.buttons[pickerID].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "沒有主機挑選鈕 \(pickerID)")
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitUntilExists(timeout: 5), "主機選單沒有 \(name)")
        option.tap()
    }

    /// 登入 Shell 標題列可換主機，不改選取中主機;下次打開選回同一台，檔案各記各的。
    @MainActor
    func testLoginShellPicksHostAndRemembersIt() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnpairedHTTPSHost"])
        openMenuItem("menu.loginShell", in: app)

        let picker = app.buttons["loginShell.host"].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "登入 Shell 沒有主機挑選鈕")
        XCTAssertTrue(picker.label.contains("Studio Mac"), "預設不是選取中主機:\(picker.label)")
        picker.tap()
        XCTAssertTrue(app.buttons["Demo"].firstMatch.waitUntilExists(timeout: 5), "主機選單沒有 Demo")
        XCTAssertFalse(app.buttons["Studio HTTPS"].exists, "HTTPS 主機不支援登入 Shell,不該列出")
        app.buttons["Demo"].firstMatch.tap()

        XCTAssertTrue(app.waitForTerminalHeader(containing: "Demo", timeout: 10), "沒有換到 Demo:\(app.terminalHeader)")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openMenuItem("menu.loginShell", in: app)
        XCTAssertTrue(app.buttons["loginShell.host"].firstMatch.waitUntilExists(timeout: 10))
        XCTAssertTrue(app.buttons["loginShell.host"].firstMatch.label.contains("Demo"), "沒有記住上次選的主機")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 5), "離開登入 Shell 後 tab bar 沒有回來")

        // 檔案 tab 跟著選取中主機(Studio Mac),不沿用登入 Shell 的選擇。
        openMenuItem("menu.files", in: app)
        XCTAssertTrue(app.buttons["files.host"].firstMatch.waitUntilExists(timeout: 10), "檔案沒有主機挑選鈕")
        XCTAssertTrue(app.buttons["files.host"].firstMatch.label.contains("Studio Mac"), "檔案不該沿用登入 Shell 的選擇")
    }

    /// 範例主機總頁保留「登入 Shell」(#434,對設計稿的刻意偏離):進 Demo 的模擬終端機,App Review 用。
    @MainActor
    func testDemoHostKeepsLoginShell() {
        let app = XCUIApplication.launchUITesting()
        openMenuItem("menu.loginShell", in: app)
        XCTAssertTrue(app.waitForTerminalHeader(containing: "Demo", timeout: 10), "範例主機的登入 Shell 沒有開到 Demo 終端機:\(app.terminalHeader)")
    }

    /// 檔案換主機後從那台的家目錄重新列出。
    @MainActor
    func testFilesPicksHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openMenuItem("menu.files", in: app)
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitUntilExists(timeout: 10), "沒有列出家目錄")
        XCTAssertEqual(app.buttons["files.crumb.0"].firstMatch.label, "Home Folder")

        pickHost("Demo", with: "files.host", in: app)

        XCTAssertTrue(app.buttons["files.host"].firstMatch.label.contains("Demo"), "沒有換到 Demo")
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitUntilExists(timeout: 10), "換主機後沒有重新列出家目錄")
    }

    /// 新增聊天右上有電腦圖示的主機選單(#621)：預設選取中主機(聊天列表篩選為所有主機),列出所有主機。
    @MainActor
    func testNewChatPicksHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnpairedHTTPSHost"])
        openMenuItem("menu.newChat", in: app)

        let picker = app.buttons["newChat.host"].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "新增聊天沒有主機挑選鈕")
        XCTAssertTrue(picker.label.contains("Studio Mac"), "預設不是選取中主機:\(picker.label)")

        pickHost("Demo", with: "newChat.host", in: app)

        XCTAssertTrue(app.buttons["newChat.host"].firstMatch.label.contains("Demo"), "沒有換到 Demo")
        // 資料夾欄在下方(lazy,不在 accessibility tree),往上捲才看得到。
        for _ in 0..<4 where !app.textFields["newChat.folder"].exists { app.element("newChat.page").swipeUp() }
        XCTAssertTrue(app.textFields["newChat.folder"].firstMatch.waitUntilExists(timeout: 5), "換主機後表單不見了")
    }
}
