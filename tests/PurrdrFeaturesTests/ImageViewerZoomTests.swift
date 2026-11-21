import CoreGraphics
import Testing

@testable import PurrdrFeatures

@Suite("全螢幕看圖的縮放規則(#330)")
struct ImageViewerZoomTests {
    /// 容器 400×800，寬圖縮進容器後是 400×200。
    let zoom = ImageViewerZoom(container: CGSize(width: 400, height: 800), fitted: CGSize(width: 400, height: 200))

    @Test func pinchZoomIsClampedBetweenOneAndMaximum() {
        #expect(zoom.clampedZoom(0.5) == 1)
        #expect(zoom.clampedZoom(3) == 3)
        #expect(zoom.clampedZoom(20) == ImageViewerZoom.maximumZoom)
    }

    @Test func oneTimesCannotBePanned() {
        #expect(zoom.allowsPan(zoom: 1) == false)
        #expect(zoom.allowsPan(zoom: 1.5))
        #expect(zoom.clampedOffset(CGSize(width: 50, height: 50), zoom: 1) == .zero)
    }

    @Test func panStopsAtImageEdges() {
        // 2×:圖寬 800、容器 400 → 水平最多 200;圖高 400 < 容器 800 → 垂直不能動。
        #expect(zoom.clampedOffset(CGSize(width: 999, height: 999), zoom: 2) == CGSize(width: 200, height: 0))
        #expect(zoom.clampedOffset(CGSize(width: -999, height: -5), zoom: 2) == CGSize(width: -200, height: 0))
        #expect(zoom.clampedOffset(CGSize(width: 30, height: 0), zoom: 2) == CGSize(width: 30, height: 0))
        // 8×:圖高 1600 → 垂直最多 400。
        #expect(zoom.clampedOffset(CGSize(width: 0, height: 999), zoom: 8).height == 400)
    }

    @Test func doubleTapZoomsInAroundTappedPoint() {
        let result = zoom.doubleTap(at: CGPoint(x: 100, y: 0), zoom: 1)
        #expect(result.zoom == ImageViewerZoom.doubleTapZoom)
        // 點的位置放大後仍在原處：offset = -p·(s−1) = -150,在水平範圍 ±350 內。
        #expect(result.offset == CGSize(width: -150, height: 0))
    }

    @Test func doubleTapNearEdgeIsClampedAndCenterTapStaysCentered() {
        let edge = zoom.doubleTap(at: CGPoint(x: 200, y: 0), zoom: 1)
        #expect(edge.offset.width == -300) // -200·1.5,範圍 ±(1000−400)/2 = ±300
        let center = zoom.doubleTap(at: .zero, zoom: 1)
        #expect(center.offset == .zero)
    }

    @Test func doubleTapWhenZoomedInReturnsToOneTimes() {
        let result = zoom.doubleTap(at: CGPoint(x: 100, y: 50), zoom: 3)
        #expect(result.zoom == 1)
        #expect(result.offset == .zero)
    }

    @Test func dismissOnlyAtOneTimesWhenDraggedDownFarEnough() {
        #expect(zoom.shouldDismiss(translation: CGSize(width: 0, height: 150), zoom: 1))
        #expect(zoom.shouldDismiss(translation: CGSize(width: 0, height: 80), zoom: 1) == false)
        #expect(zoom.shouldDismiss(translation: CGSize(width: 0, height: -150), zoom: 1) == false)
        #expect(zoom.shouldDismiss(translation: CGSize(width: 0, height: 150), zoom: 2) == false)
        // 斜著拖(水平比垂直多)不算下滑。
        #expect(zoom.shouldDismiss(translation: CGSize(width: 300, height: 150), zoom: 1) == false)
    }

    @Test func resizingKeepsOffsetInsideNewBounds() {
        // 旋轉後容器變寬:原本的偏移要夾進新範圍。
        let rotated = ImageViewerZoom(container: CGSize(width: 800, height: 400), fitted: CGSize(width: 400, height: 200))
        #expect(rotated.clampedOffset(CGSize(width: 200, height: 0), zoom: 1.5) == .zero)
    }
}
