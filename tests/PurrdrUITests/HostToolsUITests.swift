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
        app.typeText("ls")
        waitForScreen(screen, toContain: "demo@purrdr ~ % ls")
        XCTAssertTrue(app.buttons["terminal.key.esc"].firstMatch.isHittable, "按鍵列沒有出現")
    }

    @MainActor
    func testFilesBrowseFoldersAndGoUp() {
        let app = XCUIApplication.launchUITesting()
        openMenuItem("menu.files", in: app)

        let ledger = app.buttons["files.row.ledger"].firstMatch
        XCTAssertTrue(ledger.waitForExistence(timeout: 10), "沒有列出家目錄")
        XCTAssertTrue(app.descendants(matching: .any)["files.row..zshrc"].firstMatch.exists, "隱藏檔沒有列出")
        XCTAssertTrue(app.navigationBars["demo"].exists, "標題不是資料夾最後一段")
        XCTAssertEqual(app.buttons["files.upload"].firstMatch.label, "Upload File")
        XCTAssertEqual(app.buttons["files.up"].firstMatch.label, "Enclosing Folder")

        ledger.tap()
        XCTAssertTrue(app.descendants(matching: .any)["files.row.export.csv"].firstMatch.waitForExistence(timeout: 10), "沒有打開資料夾")
        XCTAssertTrue(app.navigationBars["ledger"].exists)

        app.buttons["files.up"].firstMatch.tap()
        XCTAssertTrue(app.buttons["files.row.ledger"].firstMatch.waitForExistence(timeout: 10), "沒有回到上一層")
    }
}
