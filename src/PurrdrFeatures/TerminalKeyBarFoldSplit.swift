import CoreGraphics

/// 終端機按鍵列遇到 iPhone Duo 直向折疊區時的切分:前段放按鍵、中間留空、後段放貼上與收起鍵盤(#69)。
public struct TerminalKeyBarFoldSplit: Equatable, Sendable {
    /// 折疊區前緣到按鍵列前緣的寬度。
    public let leadingWidth: CGFloat
    /// 折疊區(含系統給的 margins)的寬度。
    public let gapWidth: CGFloat

    /// `divisionFrames` 是按鍵列自己座標系的 `.division` 區域;不需切分時回傳 `nil`。
    public init?(barWidth: CGFloat, divisionFrames: [CGRect]) {
        let verticalFold = divisionFrames.first { frame in
            frame.height > frame.width && frame.minX < barWidth && frame.maxX > 0
        }
        guard let verticalFold else {
            return nil
        }
        let leadingWidth = max(verticalFold.minX, 0)
        let trailingStart = min(verticalFold.maxX, barWidth)
        // 任一側放不下兩顆按鍵就維持單一列，避免按鍵被擠到看不見(HIG:只做小幅調整)。
        guard leadingWidth >= Self.minimumSegmentWidth, barWidth - trailingStart >= Self.minimumSegmentWidth else {
            return nil
        }
        self.leadingWidth = leadingWidth
        self.gapWidth = trailingStart - leadingWidth
    }

    /// 外距 8 + 玻璃內距 6×2 + 兩顆 44pt 按鍵。
    static let minimumSegmentWidth: CGFloat = 108
}
