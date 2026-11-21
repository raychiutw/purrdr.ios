import XCTest

/// Shell `!` 指令(行為規格 F5.9、F6.4;#43)。只對 Demo 主機送出，走正式程式路徑。
final class ShellCommandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// 打 `!` 開頭時輸入列上方有提示;送出後出現終端機風格的區塊，長按可複製輸出或指令。
    @MainActor
    func testShellCommandShowsHintAndBlock() {
        let app = XCUIApplication.launchUITesting()
        let row = app.element("agent.row.demo/w1:p1")
        XCTAssertTrue(app.reveal(row), "沒有看到 Demo 主機的 Agent")
        row.tap()

        let text = app.element("composer.text")
        XCTAssertTrue(text.waitUntilExists(timeout: 10), "沒有輸入框")
        text.tap()
        text.typeEnglish("hello")
        XCTAssertFalse(app.element("composer.shellHint").exists, "一般草稿不該有 shell 提示")
        text.clearAndType("!ls Sources")
        XCTAssertTrue(app.element("composer.shellHint").waitUntilExists(timeout: 5), "沒有 shell 模式提示")

        app.element("composer.send").tap()

        let block = app.element("conversation.shell")
        XCTAssertTrue(block.waitUntilExists(timeout: 15), "對話紀錄沒有接上 shell 區塊")
        XCTAssertTrue(app.staticTexts["$ ls Sources"].exists, "沒有 `$ 指令`")
        let stdout = app.element("conversation.shell.stdout")
        XCTAssertTrue(stdout.waitUntilExists(timeout: 5), "沒有輸出")
        XCTAssertTrue((stdout.label).hasPrefix("demo: this is the demo host"))
        XCTAssertEqual(app.element("conversation.shell.status").label, "2 lines of output")
        XCTAssertFalse(app.element("conversation.echo").exists, "shell 區塊出現後回音應消失")
        XCTAssertFalse(app.element("composer.shellHint").exists, "送出後草稿清空，提示應消失")

        block.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Copy Output"].waitUntilExists(timeout: 5), "長按沒有「Copy Output」")
        XCTAssertTrue(app.buttons["Copy Command"].exists, "長按沒有「Copy Command」")
    }
}
