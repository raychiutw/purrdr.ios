import CoreGraphics

/// 頂端淡模糊的高度決策(#683):取「這個視圖所在視窗的場景」量到的狀態列高度,
/// iPad 多視窗時不會量到別的視窗;視圖還沒進視窗或量不到才退回預設。
enum StatusBarHeight {
    static let fallback: CGFloat = 54

    static func resolve(sceneHeight: CGFloat?) -> CGFloat {
        guard let sceneHeight, sceneHeight > 0 else { return fallback }
        return sceneHeight
    }
}
