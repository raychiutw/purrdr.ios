import XCTest

/// 「⋯」選單的登入 Shell 與檔案(行為規格 F13):Demo 主機的回顯 shell 與記憶體裡的資料夾。
final class HostToolsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openMenuItem(_ id: String, in app: XCUIApplication) {
        let more = app.buttons["toolbar.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "沒有「⋯」選單")
        more.tap()
        let item = app.buttons[id].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "選單沒有 \(id)")
        item.tap()
    }

    @MainActor
    private func waitForScreen(_ screen: XCUIElement, toContain text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in (screen.value as? String)?.contains(text) == true }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10)
        XCTAssertEqual(found, .completed, "畫面沒有出現「\(text)」:\(screen.value ?? "nil")", file: file, line: line)
    }

    @MainActor
    func testLoginShellOpensOnSelectedHost() {
        let app = XCUIApplication.launchUITesting()
        openMenuItem("menu.loginShell", in: app)

        let screen = app.descendants(matching: .any)["terminal.screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "沒有打開登入 Shell")
        waitForScreen(screen, toContain: "demo@purrdr ~ %")
        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        XCTAssertTrue(status.label.contains("Demo"), "標題不是主機名稱:\(status.label)")
        XCTAssertTrue(status.label.contains("Connected"), "狀態不對:\(status.label)")

        // 鍵盤輸入直接寫進 PTY(Demo 的 shell 會回顯);接上後終端機自動取得焦點。
        app.typeEnglish("ls")
        waitForScreen(screen, toContain: "demo@purrdr ~ % ls")
        XCTAssertTrue(app.buttons["terminal.key.esc"].firstMatch.isHittable, "按鍵列沒有出現")
    }

    /// 檔案頁(#273,原型):路徑麵包屑「~ › ledger」每段可點回那一層;右上「＋」上傳;沒有「上一層」按鈕與說明段落。
    @MainActor
    func testFilesBrowseFoldersWithBreadcrumbs() {
        let app = XCUIApplication.launchUITesting()
        openMenuItem("menu.files", in: app)

        let ledger = app.buttons["files.row.ledger"].firstMatch
        XCTAssertTrue(ledger.waitForExistence(timeout: 10), "沒有列出家目錄")
        XCTAssertTrue(app.descendants(matching: .any)["files.row..zshrc"].firstMatch.exists, "隱藏檔沒有列出")
        XCTAssertTrue(app.navigationBars["demo"].exists, "標題不是資料夾最後一段")
        XCTAssertEqual(app.buttons["files.upload"].firstMatch.label, "Upload File")
        XCTAssertFalse(app.buttons["files.up"].exists, "不該再有「上一層」按鈕")
        XCTAssertEqual(app.buttons["files.crumb.0"].firstMatch.label, "Home Folder")

        ledger.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.row.export.csv"].firstMatch.waitForExistence(timeout: 10), "沒有打開資料夾")
        XCTAssertTrue(app.navigationBars["ledger"].exists)
        XCTAssertEqual(app.buttons["files.crumb.1"].firstMatch.label, "ledger")

        app.buttons["files.crumb.0"].firstMatch.tap()
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitForExistence(timeout: 10), "點「~」沒有回到家目錄")
    }

    // MARK: - 主機挑選鈕(#245)

    @MainActor
    private func pickHost(_ name: String, with pickerID: String, in app: XCUIApplication) {
        let picker = app.buttons[pickerID].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "沒有主機挑選鈕 \(pickerID)")
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "主機選單沒有 \(name)")
        option.tap()
    }

    /// 登入 Shell 標題列可換主機，不改選取中主機;下次打開選回同一台，檔案各記各的。
    @MainActor
    func testLoginShellPicksHostAndRemembersIt() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnpairedHTTPSHost"])
        openMenuItem("menu.loginShell", in: app)

        let picker = app.buttons["loginShell.host"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "登入 Shell 沒有主機挑選鈕")
        XCTAssertTrue(picker.label.contains("Studio Mac"), "預設不是選取中主機:\(picker.label)")
        picker.tap()
        XCTAssertTrue(app.buttons["Demo"].firstMatch.waitForExistence(timeout: 5), "主機選單沒有 Demo")
        XCTAssertFalse(app.buttons["Studio HTTPS"].exists, "HTTPS 主機不支援登入 Shell,不該列出")
        app.buttons["Demo"].firstMatch.tap()

        let status = app.descendants(matching: .any)["terminal.status"].firstMatch
        let switched = NSPredicate { _, _ in status.label.contains("Demo") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: switched, object: nil)], timeout: 10), .completed,
                       "沒有換到 Demo:\(status.label)")
        // 選取中主機沒變：最後檔案的挑選鈕仍預設 Studio Mac。
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openMenuItem("menu.loginShell", in: app)
        XCTAssertTrue(app.buttons["loginShell.host"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["loginShell.host"].firstMatch.label.contains("Demo"), "沒有記住上次選的主機")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openMenuItem("menu.files", in: app)
        XCTAssertTrue(app.buttons["files.host"].firstMatch.waitForExistence(timeout: 10), "檔案沒有主機挑選鈕")
        XCTAssertTrue(app.buttons["files.host"].firstMatch.label.contains("Studio Mac"), "檔案不該沿用登入 Shell 的選擇")
    }

    /// 檔案換主機後從那台的家目錄重新列出。
    @MainActor
    func testFilesPicksHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openMenuItem("menu.files", in: app)
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitForExistence(timeout: 10), "沒有列出家目錄")
        XCTAssertEqual(app.buttons["files.crumb.0"].firstMatch.label, "Home Folder")

        pickHost("Demo", with: "files.host", in: app)

        XCTAssertTrue(app.buttons["files.host"].firstMatch.label.contains("Demo"), "沒有換到 Demo")
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitForExistence(timeout: 10), "換主機後沒有重新列出家目錄")
    }

    /// 新增聊天標題列有主機挑選鈕：預設選取中主機(聊天列表篩選為所有主機),列出所有主機。
    @MainActor
    func testNewChatPicksHost() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-seedUnpairedHTTPSHost"])
        openMenuItem("menu.newChat", in: app)

        let picker = app.buttons["newChat.host"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "新增聊天沒有主機挑選鈕")
        XCTAssertTrue(picker.label.contains("Studio Mac"), "預設不是選取中主機:\(picker.label)")

        pickHost("Demo", with: "newChat.host", in: app)

        XCTAssertTrue(app.buttons["newChat.host"].firstMatch.label.contains("Demo"), "沒有換到 Demo")
        XCTAssertTrue(app.textFields["newChat.folder"].firstMatch.exists, "換主機後表單不見了")
    }
}
