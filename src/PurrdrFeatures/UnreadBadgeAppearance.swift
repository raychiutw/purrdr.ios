#if canImport(UIKit)
import UIKit

/// 聊天 tab 的未讀數字徽章(系統 tab bar 畫的)底色改成 `AccessibleColors.unreadBadge`(#639):
/// 系統紅底白字只有約 3.3～3.6:1,不到 4.5:1。仍是系統的徽章,只換底色;字維持白色。
enum UnreadBadgeAppearance {
    @MainActor
    static func apply() {
        let item = UITabBarItem.appearance()
        item.badgeColor = AccessibleColors.unreadBadge.uiColor
        item.setBadgeTextAttributes([.foregroundColor: UIColor.white], for: .normal)
    }
}
#endif
