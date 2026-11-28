import CoreGraphics
import Testing
@testable import PurrdrFeatures

@Suite("狀態列高度")
struct StatusBarHeightTests {
    @Test("取這個視圖所在視窗的場景高度")
    func usesOwnSceneHeight() {
        #expect(StatusBarHeight.resolve(sceneHeight: 24) == 24)
        #expect(StatusBarHeight.resolve(sceneHeight: 59) == 59)
    }

    @Test("視圖還沒進視窗(nil)或量到 0 時退回 54pt")
    func fallsBackWhenUnavailable() {
        #expect(StatusBarHeight.resolve(sceneHeight: nil) == 54)
        #expect(StatusBarHeight.resolve(sceneHeight: 0) == 54)
        #expect(StatusBarHeight.resolve(sceneHeight: -1) == 54)
    }
}
