import CoreGraphics

/// 終端機按鍵列遇到 iPhone Duo 直向折疊區時的切分:前段放按鍵、中間留空、後段放貼上與收起鍵盤(#69)。
public struct TerminalKeyBarFoldSplit: Equatable, Sendable {
    /// 折疊區前緣到按鍵列前緣的寬度。
    public let leadingWidth: CGFloat
    /// 折疊區(含系統給的 margins)的寬度。
    public let gapWidth: CGFloat

    /// `divisionFrames` 是按鍵列自己座標系的 `.division` 區域;不需切分時回傳 `nil`。
    public init?(barWidth: CGFloat, divisionFrames: [CGRect]) {
        return nil
    }
}
