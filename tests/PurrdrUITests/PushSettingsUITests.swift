import XCTest

/// 帳號頁的「通知」區塊(#29、#246;#263 起每台主機一個開關)。UI 測試不連網路：`-uiTestingPlusMember` 以假後台的已開通會員啟動，
/// 通知權限當作已允許;`-seedHost` 的主機以 Demo 主機回應，外掛安裝只在記憶體。
/// 測試通知的頁內結果併在 `PlusUITests`(旗標 `-uiTestingPushTestFails`)。
final class PushSettingsUITests: XCTestCase {
    static let seededHost = "5EED0000-0000-4000-8000-000000000001"
    static let unreachableHost = "5EED0000-0000-4000-8000-000000000002"
    static let httpsHost = "5EED0000-0000-4000-8000-000000000003"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 還沒配對的 HTTPS 主機(#295):點通知列開與主機頁相同的配對;配對存好回到帳號頁，開關就能點。
    @MainActor
    func testUnpairedHTTPSHostRowOpensPairing() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember", "-seedUnpairedHTTPSHost", "-selectDemo"])
        app.openAccountSheet()

        app.openAccountNotifications()
        let https = app.switches["account.push.\(Self.httpsHost)"]
        XCTAssertTrue(https.waitUntilExists(timeout: 10), "沒有 HTTPS 主機的通知列")
        XCTAssertFalse(https.isEnabled)
        app.element("account.push.\(Self.httpsHost).status").tap()

        // 直接到引導的配對那一步:位址已帶入，輸入配對碼、測試通過後加入。
        XCTAssertTrue(app.textFields["guide.field.pairAddress"].waitUntilExists(timeout: 5), "沒有開配對")
        let code = app.textFields["guide.field.pairingCode"]
        code.tap()
        code.typeEnglish("K7QM-2XPA")
        app.buttons["guide.next"].tap()
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitUntilExists(timeout: 15), "沒有連上")
        save.tap()
        let done = app.buttons["guide.done"]
        XCTAssertTrue(done.waitUntilExists(timeout: 5))
        done.tap()

        XCTAssertTrue(https.waitUntilExists(timeout: 10), "沒有回到通知頁的通知列")
        XCTAssertTrue(https.wait(timeout: 10) { $0.isEnabled }, "配對後開關仍不能點")
    }

    // MARK: - 輔助

}
