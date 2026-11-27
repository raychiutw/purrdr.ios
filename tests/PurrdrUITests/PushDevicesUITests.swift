import XCTest

/// 帳號頁的「通知裝置」區塊(#266)。`-uiTestingPlusMember` 的假後台一開始有「Studio iPad」與一支舊版 app 的未命名裝置;
/// 這支裝置開了主機(`-seedHost`,Demo 主機回應安裝)才列出並標「This Device」。
final class PushDevicesUITests: XCTestCase {
    static let seededHost = "5EED0000-0000-4000-8000-000000000001"
    static let thisDevice = "5eed0000-0000-4000-8000-0000000000d1"
    static let studioIPad = "5eed0000-0000-4000-8000-0000000000d2"
    static let legacyDevice = "legacy-5eed00000000000000000000000000d3"

    override func setUp() {
        continueAfterFailure = false
    }

    /// 登入中的裝置也能左滑登出(#626):與列上的「Sign Out」同一個動作、先確認;目前這支左滑沒有登出。
    /// 接著列出其他裝置(名稱、型號、主機數);舊版 app 的裝置顯示「Unnamed Device」。改名後清單換成新名稱。
    /// 左滑關閉(#626):與列上的選單同一個動作、先確認(確認前列還在);關掉所有裝置後顯示系統空狀態。
    /// 最後有 App Store 訂閱的會員刪除前先處理訂閱(#412):說明頁有「管理訂閱」,繼續後才是刪除確認(同一次啟動,
    /// 原本 4 個測試合併)。
    @MainActor
    func testSignedInDevicesSwipeThenPushDevicesRenameTurnOffAndDeleteWithSubscription() {
        let app = XCUIApplication.launchUITesting(flags: ["-uiTestingPlusMember"])
        app.openAccountSheet()

        // 登入中的裝置左滑登出。
        let signInDevices = app.buttons["member.signInDevices"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: signInDevices, search: .down, timeout: 10), "帳號頁沒有登入中的裝置")
        signInDevices.tap()
        let sessionIPad = app.element("account.signInDevice.ui-session-ipad")
        XCTAssertTrue(sessionIPad.waitUntilExists(timeout: 10), "清單沒有另一支裝置")
        app.element("account.signInDevice.ui-session-this").swipeLeft()
        XCTAssertFalse(app.buttons["account.signInDevice.swipeSignOut.ui-session-this"].waitUntilExists(timeout: 1), "目前這支左滑不該有登出")
        sessionIPad.swipeLeft()
        let swipeSignOut = app.buttons["account.signInDevice.swipeSignOut.ui-session-ipad"].firstMatch
        XCTAssertTrue(swipeSignOut.waitUntilExists(timeout: 5), "左滑沒有「登出」")
        swipeSignOut.tap()
        let signOutConfirm = app.buttons["account.signInDevices.confirm"].firstMatch
        XCTAssertTrue(signOutConfirm.waitUntilExists(timeout: 5), "左滑沒有先確認")
        XCTAssertTrue(sessionIPad.exists, "確認前列不該先被移走")
        signOutConfirm.tap()
        XCTAssertTrue(sessionIPad.waitUntilGone(timeout: 10), "登出後裝置還在清單")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.element("sheet.account").waitUntilExists(timeout: 5), "返回後沒有回到帳號頁")

        // 通知裝置:列出、改名。
        openPushDevices(app)
        let ipad = app.element("account.pushDevice.\(Self.studioIPad)")
        XCTAssertTrue(ipad.waitUntilExists(timeout: 10), "沒有 Studio iPad 的列")
        XCTAssertTrue(ipad.label.contains("Studio iPad"), ipad.label)
        XCTAssertTrue(ipad.label.contains("Hosts: 2"), ipad.label)
        XCTAssertFalse(ipad.label.contains("This Device"), ipad.label)
        let legacy = app.element("account.pushDevice.\(Self.legacyDevice)")
        XCTAssertTrue(legacy.waitUntilExists(timeout: 10), "沒有舊版 app 的裝置列")
        XCTAssertTrue(legacy.label.contains("Unnamed Device"), legacy.label)

        app.buttons["account.pushDevice.\(Self.studioIPad)"].tap()
        app.buttons["Rename…"].firstMatch.tap()
        // SwiftUI 不把 identifier 帶到 alert 裡的 TextField。
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitUntilExists(timeout: 5), "沒有改名欄位")
        field.clearAndType("Desk iPad")
        app.alerts.buttons["account.pushDevices.save"].firstMatch.tap()

        ipad.expectLabel(containing: "Desk iPad")

        // 左滑關閉、空狀態。
        openPushDevices(app)
        for id in [Self.studioIPad, Self.legacyDevice] {
            let row = app.element("account.pushDevice.\(id)")
            XCTAssertTrue(row.waitUntilExists(timeout: 10), "沒有 \(id) 的列")
            XCTAssertFalse(app.element("account.pushDevices.empty").exists, "還有裝置時不該顯示空狀態")
            app.buttons["account.pushDevice.\(id)"].swipeLeft()
            let swipeTurnOff = app.buttons["account.pushDevices.swipeTurnOff"].firstMatch
            XCTAssertTrue(swipeTurnOff.waitUntilExists(timeout: 5), "左滑沒有「關閉通知」")
            XCTAssertTrue(app.buttons["account.pushDevices.swipeRename"].firstMatch.exists, "有 Plus 時左滑也要有「改名」")
            swipeTurnOff.tap()
            let confirm = app.buttons["account.pushDevices.confirmTurnOff"].firstMatch
            XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "左滑沒有先確認")
            XCTAssertTrue(row.exists, "確認前列不該先被移走")
            confirm.tap()
            XCTAssertTrue(row.waitUntilGone(timeout: 10), "關閉後仍在清單")
        }
        XCTAssertTrue(app.element("account.pushDevices.empty").waitUntilExists(timeout: 10), "沒有裝置時沒有系統空狀態")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.element("sheet.account").waitUntilExists(timeout: 5), "返回後沒有回到帳號頁")

        // 刪除會員:有訂閱先處理訂閱。
        let delete = app.buttons["member.delete"]
        XCTAssertTrue(app.scrollSheet("sheet.account", to: delete, search: .down, timeout: 10), "返回後帳號頁沒有刪除會員")
        delete.tap()
        XCTAssertTrue(app.buttons["member.deleteSubscription.manage"].waitUntilExists(timeout: 5), "沒有先處理訂閱")
        XCTAssertFalse(app.alerts["Delete Member?"].exists, "訂閱說明之前不該有刪除確認")
        app.buttons["member.deleteSubscription.continue"].tap()
        let deleteAlert = app.alerts["Delete Member?"]
        XCTAssertTrue(deleteAlert.waitUntilExists(timeout: 5))
        deleteAlert.buttons["Cancel"].tap()
    }

    // MARK: - 輔助

    /// 帳號頁捲到「Notification Devices」入口並點開子頁(設計稿第 28 組)。
    @MainActor
    private func openPushDevices(_ app: XCUIApplication) {
        let link = app.element("member.pushDevices")
        XCTAssertTrue(app.scrollSheet("sheet.account", to: link, search: .down, timeout: 10), "帳號頁沒有通知裝置入口")
        link.tap()
        XCTAssertTrue(app.element("account.pushDevices").waitUntilExists(timeout: 10), "沒有進到通知裝置子頁")
    }

}
