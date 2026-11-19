import XCTest

/// Shell `!` 指令(行為規格 F5.9、F6.4;#43)。只對 Demo 主機送出，走正式程式路徑。
final class ShellCommandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// 打 `!` 開頭時輸入列上方有提示;送出後出現終端機風格的區塊，長按可複製輸出或指令。
    @MainActor
    func testShellCommandShowsHintAndBlock() {
        let app = XCUIApplication.launchUITesting()
        let row = element("agent.row.demo/w1:p1", in: app)
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()

        let text = element("composer.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "沒有輸入框")
        text.tap()
        text.typeEnglish("hello")
        XCTAssertFalse(element("composer.shellHint", in: app).exists, "一般草稿不該有 shell 提示")
        text.clearAndType("!ls Sources")
        XCTAssertTrue(element("composer.shellHint", in: app).waitForExistence(timeout: 5), "沒有 shell 模式提示")

        element("composer.send", in: app).tap()

        let block = element("conversation.shell", in: app)
        XCTAssertTrue(block.waitForExistence(timeout: 15), "對話紀錄沒有接上 shell 區塊")
        XCTAssertTrue(app.staticTexts["$ ls Sources"].exists, "沒有 `$ 指令`")
        let stdout = element("conversation.shell.stdout", in: app)
        XCTAssertTrue(stdout.waitForExistence(timeout: 5), "沒有輸出")
        XCTAssertTrue((stdout.label).hasPrefix("demo: this is the demo host"))
        XCTAssertEqual(element("conversation.shell.status", in: app).label, "2 lines of output")
        XCTAssertFalse(element("conversation.echo", in: app).exists, "shell 區塊出現後回音應消失")
        XCTAssertFalse(element("composer.shellHint", in: app).exists, "送出後草稿清空，提示應消失")

        block.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Copy Output"].waitForExistence(timeout: 5), "長按沒有「Copy Output」")
        XCTAssertTrue(app.buttons["Copy Command"].exists, "長按沒有「Copy Command」")
    }
}
