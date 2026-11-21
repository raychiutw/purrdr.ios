import CoreGraphics

/// Pane 終端機保留電腦版面時的縮放規則(#357):不依賴 UIKit／SwiftUI,畫面只把手勢接到這組規則。
/// `content` 是電腦 Pane 的欄列數乘上 1× 的格子大小;內容左上角在容器內的位置是 `origin`(≤ 0)。
/// `zoom` 是相對「整寬放得下」的倍率,1 = 整寬放得下。
struct TerminalViewportZoom: Equatable {
    static let maximumZoom: CGFloat = 8

    var container: CGSize
    var content: CGSize

    /// 整寬放得下的縮放;容器比內容大時不放大(原尺寸就是放得下)。
    var fitScale: CGFloat {
        guard content.width > 0, container.width > 0 else { return 1 }
        return min(1, container.width / content.width)
    }

    func scale(zoom: CGFloat) -> CGFloat { fitScale * zoom }

    /// 放大不超過上限，也不小於整寬放得下。
    func clampedZoom(_ zoom: CGFloat) -> CGFloat { min(max(zoom, 1), Self.maximumZoom) }

    /// 內容比容器小的那一軸貼齊左上;超出的那一軸夾在邊界內，不會拖出空白。
    func clampedOrigin(_ origin: CGPoint, zoom: CGFloat) -> CGPoint {
        let scale = scale(zoom: zoom)
        return CGPoint(
            x: Self.clamp(origin.x, scaled: content.width * scale, container: container.width),
            y: Self.clamp(origin.y, scaled: content.height * scale, container: container.height))
    }

    private static func clamp(_ value: CGFloat, scaled: CGFloat, container: CGFloat) -> CGFloat {
        guard scaled > container else { return 0 }
        return min(max(value, container - scaled), 0)
    }

    /// 雙點兩下:在「整寬放得下」與「原尺寸」之間切換,放大時點的那一點不動。
    /// 整寬就是原尺寸(iPad)時什麼都不做。
    func doubleTap(at point: CGPoint, zoom: CGFloat, origin: CGPoint = .zero) -> (zoom: CGFloat, origin: CGPoint) {
        guard fitScale < 1 else { return (1, .zero) }
        guard zoom <= 1.001 else { return (1, .zero) }
        let target = 1 / fitScale
        return pinched(zoom: zoom, origin: origin, magnification: target / zoom, at: point, clamped: true)
    }

    /// 捏合:以手指中心為不動點縮放。`clamped` 為 false 時進行中可略超出範圍(放開再夾回)。
    func pinched(zoom: CGFloat, origin: CGPoint, magnification: CGFloat, at anchor: CGPoint, clamped: Bool = false)
        -> (zoom: CGFloat, origin: CGPoint) {
        let next = clamped ? clampedZoom(zoom * magnification) : min(max(zoom * magnification, 0.8), Self.maximumZoom * 1.2)
        let ratio = scale(zoom: next) / scale(zoom: zoom)
        let moved = CGPoint(x: anchor.x - ratio * (anchor.x - origin.x), y: anchor.y - ratio * (anchor.y - origin.y))
        return (next, clamped ? clampedOrigin(moved, zoom: next) : moved)
    }

    /// 鍵盤讓容器變矮(或內容變動)後，只在游標(內容座標、1× 格子大小)被遮住時才捲動讓它可見。
    func revealing(caret: CGRect, origin: CGPoint, zoom: CGFloat) -> CGPoint {
        let scale = scale(zoom: zoom)
        var result = origin
        let top = caret.minY * scale, bottom = caret.maxY * scale
        let left = caret.minX * scale, right = caret.maxX * scale
        if bottom + result.y > container.height { result.y = container.height - bottom }
        if top + result.y < 0 { result.y = -top }
        if right + result.x > container.width { result.x = container.width - right }
        if left + result.x < 0 { result.x = -left }
        return clampedOrigin(result, zoom: zoom)
    }
}
