import XCTest

final class IPadDebugTmpUITests: XCTestCase {
    @MainActor
    func testDump() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try XCTSkipUnless(isPad)
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication.launchUITesting()
        let row = app.element("spaces.tab.demo/w1:t1")
        XCTAssertTrue(app.reveal(row))
        row.tap()
        XCTAssertTrue(app.element("composer.text").waitUntilExists(timeout: 15))
        try? app.debugDescription.write(toFile: "/tmp/g1-dump-chat.txt", atomically: true, encoding: .utf8)
        let tab = app.element("spaces.tab.demo/w3:t1")
        XCTAssertTrue(app.reveal(tab))
        tab.tap()
        sleep(2)
        try? app.debugDescription.write(toFile: "/tmp/g1-dump-layout.txt", atomically: true, encoding: .utf8)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        try? app.debugDescription.write(toFile: "/tmp/g1-dump-cmdcomma.txt", atomically: true, encoding: .utf8)
    }
}
