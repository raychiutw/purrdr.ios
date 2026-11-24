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
            app.openNewChatSheet()
        default:
            // 登入 Shell 在主機 tab。
            app.openHostsTab()
            let item = app.overviewRow("hosts.tool.loginShell")
            XCTAssertTrue(item.exists, "主機 tab 沒有登入 Shell")
            item.tap()
        }
    }

    @MainActor
    func testLoginShellOpensOnSelectedHost() {
        // 已存主機的通道是 Demo 主機,回顯 shell(範例主機自己的入口見 testDemoHostKeepsLoginShell)。
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openMenuItem("menu.loginShell", in: app)

        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        XCTAssertTrue(screen.waitUntilExists(timeout: 10), "沒有打開登入 Shell")
        screen.expectValue(containing: "demo@purrdr ~ %")
        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        XCTAssertTrue(status.label.contains("Studio Mac"), "標題不是主機名稱:\(status.label)")
        XCTAssertTrue(status.label.contains("Connected"), "狀態不對:\(status.label)")

        // 鍵盤輸入直接寫進 PTY(Demo 的 shell 會回顯);接上後終端機自動取得焦點。
        app.typeEnglish("ls")
        screen.expectValue(containing: "demo@purrdr ~ % ls")
        XCTAssertTrue(app.buttons["terminal.key.esc"].firstMatch.isHittable, "按鍵列沒有出現")
    }

    /// 檔案頁(#273,原型):路徑麵包屑「~ › ledger」每段可點回那一層;右上「＋」上傳;沒有「上一層」按鈕與說明段落。
    @MainActor
    func testFilesBrowseFoldersWithBreadcrumbs() {
        let app = XCUIApplication.launchUITesting()
        openMenuItem("menu.files", in: app)

        let ledger = app.buttons["files.row.ledger"].firstMatch
        XCTAssertTrue(ledger.waitUntilExists(timeout: 10), "沒有列出家目錄")
        XCTAssertTrue(app.descendants(matching: .any)["files.row..zshrc"].firstMatch.exists, "隱藏檔沒有列出")
        XCTAssertEqual(app.staticTexts["topBar.title"].firstMatch.label, "Files", "檔案頁的大標題不是 tab 名稱")
        XCTAssertEqual(app.buttons["files.upload"].firstMatch.label, "Upload File")
        XCTAssertFalse(app.buttons["files.up"].exists, "不該再有「上一層」按鈕")
        XCTAssertEqual(app.buttons["files.crumb.0"].firstMatch.label, "Home Folder")

        ledger.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.row.export.csv"].firstMatch.waitUntilExists(timeout: 10), "沒有打開資料夾")
        XCTAssertEqual(app.buttons["files.crumb.1"].firstMatch.label, "ledger")

        app.buttons["files.crumb.0"].firstMatch.tap()
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitUntilExists(timeout: 10), "點「~」沒有回到家目錄")
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

        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        XCTAssertTrue(status.waitForLabel(containing: "Demo", timeout: 10), "沒有換到 Demo:\(status.label)")
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
        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        XCTAssertTrue(status.waitForLabel(containing: "Demo", timeout: 10), "範例主機的登入 Shell 沒有開到 Demo 終端機:\(status.label)")
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

    /// 新增聊天標題列有主機挑選鈕：預設選取中主機(聊天列表篩選為所有主機),列出所有主機。
    @MainActor
    func testNewChatPicksHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnpairedHTTPSHost"])
        openMenuItem("menu.newChat", in: app)

        let picker = app.buttons["newChat.host"].firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "新增聊天沒有主機挑選鈕")
        XCTAssertTrue(picker.label.contains("Studio Mac"), "預設不是選取中主機:\(picker.label)")

        pickHost("Demo", with: "newChat.host", in: app)

        XCTAssertTrue(app.buttons["newChat.host"].firstMatch.label.contains("Demo"), "沒有換到 Demo")
        // 新增對話是部分高度的 sheet(#425):資料夾欄在下方(lazy,不在 accessibility tree),拉到 large 才看得到。
        for _ in 0..<4 where !app.textFields["newChat.folder"].exists { app.element("sheet.newChat").swipeUp() }
        XCTAssertTrue(app.textFields["newChat.folder"].firstMatch.waitUntilExists(timeout: 5), "換主機後表單不見了")
    }
}
