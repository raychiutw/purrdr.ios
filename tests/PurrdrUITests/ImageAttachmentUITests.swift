import UIKit
import XCTest

/// 傳圖片(行為規格 F7;#16、#37 故事 33–35)。走 Demo 主機的正式程式路徑(上傳、prompt、對話紀錄讀回)。
///
/// 相簿是系統的 out-of-process PhotosPicker,UI 測試不操作它;圖片從剪貼簿來(測試程序寫進模擬器的剪貼簿)。
final class ImageAttachmentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        UIPasteboard.general.items = []
    }

    @MainActor
    private func openLedger() -> XCUIApplication {
        let app = XCUIApplication.launchUITesting()
        let row = app.descendants(matching: .any)["agent.row.w1:p1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "沒有看到 Demo 主機的 Agent")
        row.tap()
        XCTAssertTrue(element("conversation.user", in: app).waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private static func putImageOnPasteboard() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        UIPasteboard.general.image = image
    }

    /// 接實體鍵盤時 Command-V(剪貼簿只有圖片)把它加成附件;只有圖片也可送;
    /// 送出後 Demo 的對話紀錄把路徑記成圖片，泡泡顯示手機上的副本，點開全螢幕、點一下關閉。
    @MainActor
    func testPasteImageSendAndViewFullScreen() {
        Self.putImageOnPasteboard()
        let app = openLedger()

        let text = element("composer.text", in: app)
        text.tap()
        text.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(element("composer.attachment.0", in: app).waitForExistence(timeout: 5), "Command-V 沒有把圖片加成附件")
        XCTAssertEqual(text.value as? String ?? "", "", "Command-V 不該貼上文字")
        let send = element("composer.send", in: app)
        XCTAssertTrue(send.isEnabled, "只有圖片也要能送")
        send.tap()

        XCTAssertTrue(element("composer.attachment.0", in: app).waitForNonExistence(timeout: 10), "送出被接受後附件要清空")
        let image = element("conversation.image", in: app)
        XCTAssertTrue(image.waitForExistence(timeout: 10), "泡泡沒有顯示圖片")
        XCTAssertLessThanOrEqual(max(image.frame.width, image.frame.height), 221, "泡泡圖片長邊應是 220pt")
        image.tap()

        let viewer = element("image.viewer", in: app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "點泡泡圖片沒有全螢幕檢視")
        viewer.tap()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5), "點一下沒有關閉全螢幕檢視")
    }

    /// 剪貼簿有圖時，「加入圖片」先問「相簿／貼上圖片」;按鈕有 label、至少 44pt。
    @MainActor
    func testAddImageAsksSourceWhenPasteboardHasImage() {
        Self.putImageOnPasteboard()
        let app = openLedger()

        let add = element("composer.addImage", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5), "沒有「加入圖片」")
        XCTAssertEqual(add.label, "Add Image")
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        add.tap()

        XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 5), "沒有問「相簿」")
        XCTAssertTrue(app.buttons["Paste Image"].exists, "沒有問「貼上圖片」")
        app.buttons["Cancel"].firstMatch.tap()
    }
}
