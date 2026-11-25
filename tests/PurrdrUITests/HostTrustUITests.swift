import XCTest

/// 第一次以 SSH 連到主機時的「信任這台主機?」確認(#613、spec #612):左 X、右 ✓「Trust」,可點。
/// `-uiTestingHostKeyPrompt` 讓還沒有 host key pin 的 SSH 主機出示未信任的 host key(Demo 主機平常不會走到這一步)。
final class HostTrustUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTrustPromptHasCloseAndConfirmAndWorks() throws {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-uiTestingHostKeyPrompt"])
        app.openHostsTab()
        app.overviewRow("hosts.edit").tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitUntilExists(timeout: 5))

        // 改成自己的 sshd + 密碼登入(Tailscale SSH 的身分由 tailnet 確認,不會問)。
        let openSSH = app.descendants(matching: .any)["hostEditor.method.openSSH"].firstMatch
        app.scrollIntoView(openSSH, timeout: 5)
        openSSH.tap()
        let signIn = app.descendants(matching: .any)["hostEditor.signIn"].firstMatch
        app.scrollIntoView(signIn, timeout: 5)
        app.buttons["Password"].firstMatch.tapWhenReady()
        let password = app.secureTextFields["hostEditor.password"]
        XCTAssertTrue(password.waitUntilExists(timeout: 5))
        password.tap()
        password.typeEnglish("hunter2")

        let test = app.buttons["hostEditor.test"]
        app.scrollIntoView(test, timeout: 5)
        test.tap()

        // 第一次:有左 X 與右 ✓「Trust」;X 關掉不信任。
        let cancel = app.buttons["hostTrust.cancel"]
        let trust = app.buttons["hostTrust.trust"]
        XCTAssertTrue(cancel.waitUntilExists(timeout: 10), "沒有出現信任主機的確認")
        XCTAssertTrue(trust.exists, "沒有右上 ✓ Trust")
        XCTAssertTrue(trust.isHittable && cancel.isHittable, "X 或 Trust 點不到")
        XCTAssertEqual(trust.label, "Trust")
        XCTAssertTrue(app.staticTexts["hostTrust.question"].exists, "沒有「Trust this host?」的說明")
        cancel.tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { !trust.exists }, "按 X 後確認沒有關閉")

        // 第二次:信任後確認關閉,連線測試通過。
        app.scrollIntoView(test, timeout: 5)
        test.tap()
        XCTAssertTrue(trust.waitUntilExists(timeout: 10), "再測試一次沒有出現確認")
        trust.tap()
        XCTAssertTrue(UITestWait.until(timeout: 5) { !trust.exists }, "按 Trust 後確認沒有關閉")
        XCTAssertTrue(app.descendants(matching: .any)["hostEditor.result"].firstMatch.waitUntilExists(timeout: 15), "信任後沒有連線結果")
    }
}
