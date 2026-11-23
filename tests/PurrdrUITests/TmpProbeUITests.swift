import XCTest

final class TmpProbeUITests: XCTestCase {
    static let dir = "/private/tmp/claude-501/-Users-ray-Projects-purrdr-ios/ba967249-d8ed-477e-b5a4-4f2aff054f11/scratchpad/shots/fix51/"
    func shot(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: Self.dir + name + ".png"))
        try? app.debugDescription.write(toFile: Self.dir + name + ".txt", atomically: true, encoding: .utf8)
    }
    @MainActor
    func testProbe() {
        let app = XCUIApplication.launchUITestingConversation(paneID: "w1:p1", flags: ["-demoSentImages"], contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        _ = app.conversationList.waitUntilExists(timeout: 10)
        sleep(3)
        shot(app, "img-0")
        let t = app.element("conversation.sentImage.thumbnail")
        print("PROBE thumb", t.exists)
        print("PROBE list value", app.conversationList.value ?? "nil")
        let ok = app.revealInConversation(t)
        print("PROBE reveal", ok)
        shot(app, "img-1")
    }
}
