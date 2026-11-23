import CoreGraphics

/// 全螢幕看圖(`ImageViewerZoom`)的縮放數學:倍率的上下限、捏合進行中的橡皮筋範圍、以手指為不動點的位置換算。
/// (Pane 終端機已改為顯示時持有手機尺寸、不縮放,#357;原本共用這份的 `TerminalViewportZoom` 已刪除。)
enum ZoomMath {
    static let maximumZoom: CGFloat = 8
    /// 捏合進行中可略超出範圍的下限(放開時彈回 1×)。
    static let rubberBandMinimum: CGFloat = 0.8
    /// 捏合進行中可略超出範圍的上限係數。
    static let rubberBandMaximumFactor: CGFloat = 1.2

    /// 放開時夾在 1× 到上限之間。
    static func clampedZoom(_ zoom: CGFloat) -> CGFloat { min(max(zoom, 1), maximumZoom) }

    /// 捏合進行中的倍率:可略超出範圍(橡皮筋感)。
    static func rubberBandedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, rubberBandMinimum), maximumZoom * rubberBandMaximumFactor)
    }

    /// 以 `anchor` 為不動點縮放 `ratio` 倍後,內容原點的新位置:手指下的那一點縮放後仍在手指下。
    static func anchored(origin: CGPoint, anchor: CGPoint, ratio: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x - ratio * (anchor.x - origin.x), y: anchor.y - ratio * (anchor.y - origin.y))
    }
}
