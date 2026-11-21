import CoreGraphics
import Testing

@testable import PurrdrFeatures

@Suite("Pane 終端機保留版面的縮放規則(#357)")
struct TerminalViewportZoomTests {
    /// 電腦的 Pane 是 100×40 格,每格 8×16 pt → 內容 800×640;手機容器 400×700。
    let wide = TerminalViewportZoom(container: CGSize(width: 400, height: 700), content: CGSize(width: 800, height: 640))

    @Test func fitsTheWholeWidth() {
        #expect(wide.fitScale == 0.5)
        #expect(wide.scale(zoom: 1) == 0.5)
    }

    @Test func neverScalesUpPastActualSize() {
        // iPad:容器比內容大，不放大，原尺寸就是「放得下」。
        let ipad = TerminalViewportZoom(container: CGSize(width: 1000, height: 800), content: CGSize(width: 800, height: 640))
        #expect(ipad.fitScale == 1)
    }

    @Test func pinchIsClampedBetweenFitAndMaximum() {
        #expect(wide.clampedZoom(0.3) == 1)
        #expect(wide.clampedZoom(3) == 3)
        #expect(wide.clampedZoom(99) == TerminalViewportZoom.maximumZoom)
    }

    @Test func contentSmallerThanContainerStaysTopLeft() {
        #expect(wide.clampedOrigin(CGPoint(x: 50, y: -30), zoom: 1) == .zero)
    }

    @Test func panStopsAtTheEdges() {
        // zoom 2 → scale 1.0 → 800×640:寬超出 400,高沒超出。
        #expect(wide.clampedOrigin(CGPoint(x: -999, y: -999), zoom: 2) == CGPoint(x: -400, y: 0))
        #expect(wide.clampedOrigin(CGPoint(x: 80, y: 0), zoom: 2) == .zero)
    }

    @Test func doubleTapTogglesBetweenFitAndActualSize() {
        let zoomed = wide.doubleTap(at: CGPoint(x: 200, y: 100), zoom: 1)
        #expect(zoomed.zoom == 2)   // 0.5 → 1.0 原尺寸
        // 點的那一點不動:內容座標 (400,200) 原本在螢幕 (200,100),放大後仍在那裡;y 因內容沒超出而貼頂。
        #expect(zoomed.origin == CGPoint(x: -200, y: 0))
        #expect(wide.doubleTap(at: .zero, zoom: 2).zoom == 1)
        #expect(wide.doubleTap(at: .zero, zoom: 2).origin == .zero)
    }

    @Test func doubleTapDoesNothingWhenAlreadyActualSize() {
        let ipad = TerminalViewportZoom(container: CGSize(width: 1000, height: 800), content: CGSize(width: 800, height: 640))
        #expect(ipad.doubleTap(at: .zero, zoom: 1).zoom == 1)
    }

    @Test func keyboardShrinkingTheContainerScrollsCaretIntoView() {
        // 容器被鍵盤壓成 400×300,內容放大到 1.0(800×640);游標在內容座標 (100, 600)。
        let keyboard = TerminalViewportZoom(container: CGSize(width: 400, height: 300), content: CGSize(width: 800, height: 640))
        let origin = keyboard.revealing(caret: CGRect(x: 100, y: 600, width: 8, height: 16), origin: .zero, zoom: 2)
        // 游標底 616 要落在容器內:origin.y = 300 - 616 = -316,夾在 [-340, 0] 內。
        #expect(origin == CGPoint(x: 0, y: -316))
    }

    @Test func caretAlreadyVisibleDoesNotMove() {
        #expect(wide.revealing(caret: CGRect(x: 10, y: 10, width: 8, height: 16), origin: .zero, zoom: 1) == .zero)
    }
}
