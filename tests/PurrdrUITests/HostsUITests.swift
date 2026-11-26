import XCTest

/// 主機 tab 的單台主機總頁與主機編輯(UI 測試只用 Demo 主機，不連網路);新增主機的流程在 `AddHostGuideUITests`。
final class HostsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    @MainActor
    private func openHosts(_ app: XCUIApplication) {
        app.openHostsTab()
    }

    /// 在主機清單打開已存主機的編輯器，點名稱欄叫出鍵盤(`edits` 為真時再改名)，按左上角取消(#333:不能閃退)。
    /// 沒改動時直接關閉;改了名稱時先出現放棄確認，確認後回到主機總頁。
    @MainActor
    private func cancelEditingWithKeyboardUp(_ app: XCUIApplication, edits: Bool, label: String) {
        let edit = app.overviewRow("hosts.edit")
        XCTAssertTrue(edit.waitUntilExists(timeout: 5))
        edit.tap()
        let name = app.textFields["hostEditor.name"]
        XCTAssertTrue(name.waitUntilExists(timeout: 5))
        XCTAssertTrue(app.focusTextField(name), "名稱欄沒有取得焦點")
        XCTAssertTrue(app.waitForKeyboard(), "沒有叫出鍵盤")
        if edits { name.typeEnglish("2") }

        // 左上是系統返回鈕(#622);沒有另外的 Cancel。
        XCTAssertFalse(app.navigationBars.buttons["Cancel"].exists, "編輯主機不該有 Cancel")
        if edits {
            // 有未存修改時左緣滑回也不能直接離開(要先確認)。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            XCTAssertTrue(app.textFields["hostEditor.name"].waitUntilExists(timeout: 3), "有未存修改時左緣滑回直接離開了編輯頁")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "點取消後 app 不在前景(閃退) \(label) edits=\(edits)")
        if edits {
            let discard = app.buttons["Discard Changes"].firstMatch
            let discardZh = app.buttons["放棄變更"].firstMatch
            XCTAssertTrue(UITestWait.until(timeout: 5) { discard.exists || discardZh.exists }, "沒有放棄確認")
            (discard.exists ? discard : discardZh).tap()
        }
        XCTAssertTrue(app.overviewRow("hosts.edit").waitUntilExists(timeout: 5), "沒有回到主機總頁")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 已存主機的總頁與編輯一次啟動走完(#374 瘦身;原本各自啟動):總頁、開編輯器、取消編輯(#333)、
    /// 改圖示、改名稱(不必測試連線)、分享、移除(先確認,取消就不移除),最後以深層連結匯入主機(放最後:匯入的主機會變成選取中主機)。
    @MainActor
    func testSeededHostOverviewAndEditor() throws {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost"])
        openHosts(app)

        // 總頁(#392):頂列是主機選單,沒有清單頁;上面是連線狀態,下面是這台主機的入口。
        step("總頁只有這台主機") {
            XCTAssertTrue(app.element("hosts.status").waitUntilExists(timeout: 10), "沒有連線狀態")
            XCTAssertTrue(app.element("hosts.status").exists, "沒有連線狀態")
            XCTAssertTrue(app.buttons["hosts.host"].firstMatch.exists, "主機 tab 右上要有電腦圖示選單(#616)")
            for id in ["hosts.tool.notifications.locked", "hosts.share", "hosts.settings", "hosts.edit", "hosts.delete"] {
                XCTAssertTrue(app.overviewRow(id).exists, "總頁沒有 \(id)")
            }
            XCTAssertFalse(app.buttons["hosts.demo"].exists, "不該再有主機清單")
            XCTAssertFalse(app.buttons["hosts.host.Studio Mac"].exists, "主機頁內不該有主機清單列(選主機在右上選單)")
        }

        step("開編輯器") {
            app.overviewRow("hosts.edit").tap()
            XCTAssertTrue(app.navigationBars["Edit Host"].waitUntilExists(timeout: 5))
            XCTAssertEqual(app.textFields["hostEditor.name"].value as? String, "Studio Mac")
            // 連線方式是系統的勾選清單(`.inline` Picker),三種方式都在,目前這台是選中的(#622)。
            for raw in ["tailscaleSSH", "openSSH", "https"] {
                XCTAssertTrue(app.descendants(matching: .any)["hostEditor.method.\(raw)"].firstMatch.exists, "沒有連線方式 \(raw)")
            }
            XCTAssertFalse(app.navigationBars.buttons["Cancel"].exists, "編輯主機左上是系統返回鈕,沒有 Cancel")
            XCTAssertTrue(app.buttons["hostEditor.save"].exists, "編輯主機右上是儲存")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        step("取消編輯:沒改動與改了名稱") {
            cancelEditingWithKeyboardUp(app, edits: false, label: "en")
            cancelEditingWithKeyboardUp(app, edits: true, label: "en")
        }

        // 編輯器的圖示欄位：11 種加「無」;只改圖示不必重新測試連線就能儲存，再開編輯器仍是選的那個。
        step("編輯器改圖示不必重新測試") {
            app.overviewRow("hosts.edit").tap()
            let desktop = app.buttons["hostEditor.icon.desktop"]
            XCTAssertTrue(desktop.waitUntilExists(timeout: 5))
            XCTAssertTrue(desktop.isSelected, "沒選過圖示的主機是桌機")
            for raw in ["laptop", "macMini", "rack", "pc", "display", "board", "console", "home", "cloud", "terminal", "none"] {
                XCTAssertTrue(app.buttons["hostEditor.icon.\(raw)"].exists, raw)
            }

            let board = app.buttons["hostEditor.icon.board"]
            board.tap()
            XCTAssertTrue(board.isSelected)
            XCTAssertFalse(desktop.isSelected)
            let save = app.buttons["hostEditor.save"]
            XCTAssertTrue(save.isEnabled, "只改圖示不必重新測試連線")
            save.tap()

            // 儲存後回到總頁;再開一次確認圖示存起來了。
            XCTAssertTrue(app.overviewRow("hosts.edit").waitUntilExists(timeout: 5), "儲存後沒有回到總頁")
            app.overviewRow("hosts.edit").tap()
            XCTAssertTrue(app.buttons["hostEditor.icon.board"].waitUntilExists(timeout: 5))
            XCTAssertTrue(app.buttons["hostEditor.icon.board"].isSelected)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // 只改名稱也不必重新測試連線;頂列的主機選單換成新名稱。
        step("編輯器改名不必重新測試") {
            app.overviewRow("hosts.edit").tap()
            let name = app.textFields["hostEditor.name"]
            XCTAssertTrue(name.waitUntilExists(timeout: 5))
            name.clearAndType("Office Mac")
            let save = app.buttons["hostEditor.save"]
            XCTAssertTrue(save.isEnabled, "只改名稱不必重新測試連線")
            save.tap()
            // 回到總頁時列表還停在剛才捲到的位置,狀態卡在最上面(lazy):先捲回上面。
            let status = app.element("hosts.status")
            XCTAssertTrue(app.scrollIntoView(status, search: .up, timeout: 5), "存檔後沒有回到總頁")
            let picker = app.buttons["hosts.host"].firstMatch
            XCTAssertTrue(UITestWait.until(timeout: 10) { picker.label.contains("Office Mac") }, "右上主機選單沒有換成新名稱:\(picker.label)")
        }

        // 分享:在同一個 NavigationStack push,顯示 QR code 與分享連結。
        step("分享") {
            app.overviewRow("hosts.share").tap()
            // `.accessibilityElement()` 讓 QR code 以 Other(而非 Image)出現在 accessibility tree。
            XCTAssertTrue(app.descendants(matching: .any)["hostShare.qr"].firstMatch.waitUntilExists(timeout: 5))
            XCTAssertTrue(app.buttons["hostShare.link"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.overviewRow("hosts.share").waitUntilExists(timeout: 5))
        }

        // 移除主機:先確認(HIG Alerts),取消就不移除;確認後選取改回範例主機。
        step("移除主機先確認") {
            app.overviewRow("hosts.delete").tap()
            let confirm = app.buttons["hosts.delete.confirm"].firstMatch
            XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "移除主機要先確認")
            XCTAssertFalse(app.alerts.firstMatch.exists, "移除主機的確認是底部選項,不是中央對話框")
            XCTAssertTrue(app.sheets.firstMatch.exists, "移除主機沒有出現 action sheet")
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
            XCTAssertTrue(confirm.waitUntilGone(timeout: 5))
            XCTAssertTrue(app.overviewRow("hosts.edit").exists, "取消後主機還在")

            app.overviewRow("hosts.delete").tap()
            XCTAssertTrue(confirm.waitUntilExists(timeout: 5), "移除主機要先確認")
            confirm.tap()
            XCTAssertTrue(app.buttons["hosts.demo.remove"].waitUntilExists(timeout: 5), "移除後沒有回到範例主機")
            XCTAssertFalse(app.buttons["hosts.edit"].exists)
        }

        // 掃 QR code／點分享連結(深層連結)→ 主機 tab 開出新增主機引導，資料已齊，停在測試連線的確認頁(顯示連線目標，#573);按下「Test Connection」才測試，通過後才能加入。
        step("分享連結開引導停在確認頁，按下才測試") {
            XCTAssertTrue(app.tabBars.firstMatch.waitUntilExists(timeout: 10))
            // HostShareLink:name Studio Mac、host studio-mac、port 22、user demo。
            let payload = #"{"host":"studio-mac","method":"tailscaleSSH","name":"Studio Mac","port":22,"user":"demo","v":1}"#
            let encoded = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            app.open(URL(string: "purrdr://host?d=\(encoded)")!)

            // #573:只到確認頁,顯示連線目標、還沒測試;按下才測試連線。
            let confirm = app.buttons["guide.confirmTest"]
            XCTAssertTrue(confirm.waitUntilExists(timeout: 15), "沒有停在測試連線的確認頁\n\(app.debugDescription)")
            XCTAssertTrue(app.staticTexts["guide.target"].exists, "確認頁沒有顯示連線目標")
            XCTAssertFalse(app.buttons["guide.save"].exists, "確認前不該已通過測試")
            confirm.tap()
            let save = app.buttons["guide.save"]
            XCTAssertTrue(save.waitUntilExists(timeout: 15), "按下測試後沒有通過連線測試\n\(app.debugDescription)")
            save.tap()
            app.buttons["guide.done"].tapWhenReady()
            app.openHostsTab()
            // 匯入的主機成為選取中主機:右上電腦圖示選單的標籤是「Host: 主機名」(#616)。
            let picker = app.buttons["hosts.host"].firstMatch
            XCTAssertTrue(picker.waitUntilExists(timeout: 5), "主機 tab 右上沒有電腦圖示選單")
            let selected = UITestWait.until(timeout: 10) { picker.label.contains("Studio Mac") }
            XCTAssertTrue(selected, "匯入的主機不是選取中主機:\(picker.label)")
        }
    }

    /// 繁體中文介面下取消編輯(#333;放棄確認的按鈕是中文)。語言要重新啟動才能換，所以另開一次。
    @MainActor
    func testCancelEditingInTraditionalChinese() {
        let app = XCUIApplication.launchUITesting(flags: ["-seedHost", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"])
        openHosts(app)
        cancelEditingWithKeyboardUp(app, edits: false, label: "zh-Hant")
        cancelEditingWithKeyboardUp(app, edits: true, label: "zh-Hant")
    }
}

extension XCUIElement {
    /// 清掉文字欄位原本的內容再輸入。
    @MainActor
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeEnglish(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeEnglish(text)
    }
}

