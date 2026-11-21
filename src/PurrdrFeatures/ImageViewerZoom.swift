import CoreGraphics

/// 全螢幕看圖(#330)的縮放規則：不依賴 UIKit／SwiftUI，畫面只把手勢接到這組規則。
/// 座標以容器中心為原點；`fitted` 是圖片在 1× 時等比縮進容器後的尺寸。
struct ImageViewerZoom: Equatable {
    static let maximumZoom: CGFloat = 8
    static let doubleTapZoom: CGFloat = 2.5
    /// 1× 時向下拖超過這麼多(pt)放開就關閉。
    static let dismissDistance: CGFloat = 120

    var container: CGSize
    var fitted: CGSize

    /// 捏合結果夾在 1× 到上限之間(放開時彈回)。
    func clampedZoom(_ zoom: CGFloat) -> CGFloat { min(max(zoom, 1), Self.maximumZoom) }

    /// 放大後圖片超出容器的一半，就是單邊可平移的最大值;沒超出的方向不能動。
    func maximumOffset(zoom: CGFloat) -> CGSize {
        CGSize(
            width: max(0, (fitted.width * zoom - container.width) / 2),
            height: max(0, (fitted.height * zoom - container.height) / 2))
    }

    /// 平移夾在邊界內，圖不會被拖出畫面;1× 一律回到中心。
    func clampedOffset(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        guard allowsPan(zoom: zoom) else { return .zero }
        let limit = maximumOffset(zoom: zoom)
        return CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height))
    }

    /// 雙點兩下:沒放大就以點的位置(相對容器中心)為中心放大，已放大就回 1×。
    func doubleTap(at point: CGPoint, zoom: CGFloat) -> (zoom: CGFloat, offset: CGSize) {
        guard zoom <= 1 else { return (1, .zero) }
        let target = Self.doubleTapZoom
        let offset = CGSize(width: -point.x * (target - 1), height: -point.y * (target - 1))
        return (target, clampedOffset(offset, zoom: target))
    }

    /// 捏合進行中:以手指中心(`anchor`,相對容器中心)為不動點縮放——手指下的那一點縮放後仍在手指下。
    /// 進行中可略超出範圍(橡皮筋感),放開時再以 `clampedZoom`／`clampedOffset` 夾回。
    func pinched(zoom start: CGFloat, offset: CGSize, magnification: CGFloat, at anchor: CGPoint) -> (zoom: CGFloat, offset: CGSize) {
        let zoom = min(max(start * magnification, 0.8), Self.maximumZoom * 1.2)
        let ratio = zoom / start
        // 手指下的圖上的點 p = (anchor - offset) / start;縮放後仍要在 anchor,所以新的 offset = anchor - zoom * p。
        return (zoom, CGSize(
            width: anchor.x - ratio * (anchor.x - offset.width), height: anchor.y - ratio * (anchor.y - offset.height)))
    }

    /// 放大後才能單指平移。
    func allowsPan(zoom: CGFloat) -> Bool { zoom > 1.001 }

    /// 1× 時往下滑夠遠、而且主要是垂直方向，才關閉。
    func shouldDismiss(translation: CGSize, zoom: CGFloat) -> Bool {
        !allowsPan(zoom: zoom) && translation.height > Self.dismissDistance && translation.height > abs(translation.width)
    }
}
