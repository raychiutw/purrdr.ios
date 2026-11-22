import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension AppearancePreference {
    /// `nil` 跟隨系統。
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }

    #if canImport(UIKit)
    /// 視窗層級的覆寫;自動是 `.unspecified`(跟隨系統)。
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .automatic: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
    #endif
}

extension View {
    /// 套用設定頁的外觀(#246)。每個視窗的根畫面都要掛(含 App 鎖的鎖定視窗);設定改了立即生效。
    public func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.automatic

    func body(content: Content) -> some View {
        #if os(iOS)
        // 設在所在 UIWindow 的 overrideUserInterfaceStyle,不用 `preferredColorScheme`(#322):
        // 後者不會更新已經開著的 sheet(sheet 停在開啟時的深淺色)。視窗層級的覆寫同一個視窗裡的
        // sheet、alert 都跟著變，自動(`.unspecified`)也確實回到系統值。
        content.background { WindowAppearanceApplier(style: appearance.userInterfaceStyle) }
        #else
        content.preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(iOS)
/// 視窗層級的外觀與底色層次(#379)。
///
/// 深色頁面底色由系統的純黑改為提亮值:視窗固定用 `elevated` 介面層級,系統的語意底色就整組上移一階——
/// 頁面(`systemBackground`、`systemGroupedBackground`)#1C1C1E、卡片與 grouped 列(`secondarySystemBackground`、
/// `secondarySystemGroupedBackground`)#2C2C2E、再內一層 #3A3A3C。所有畫面用的是語意色,所以全 app 一致、
/// 切換畫面不跳色,「增加對比」與淺色(介面層級對淺色沒有影響)照系統。
/// sheet 本來就是 elevated,所以與頁面同色階、sheet 內的列是 #2C2C2E(使用者決定接受,不逐列自訂背景;設計稿的 sheet 再高一階留待後續票)。
package enum AppWindowSurface {
    @MainActor
    package static func apply(to window: UIWindow, style: UIUserInterfaceStyle) {
        if window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
        }
        // 不先讀:UITraitOverrides 取沒設過的 trait 會觸發 assertion。
        window.traitOverrides.userInterfaceLevel = .elevated
    }
}

/// 把外觀套到自己所在的 UIWindow。
private struct WindowAppearanceApplier: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        return anchor
    }

    func updateUIView(_ anchor: AnchorView, context: Context) {
        anchor.style = style
    }

    final class AnchorView: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { apply() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            AppWindowSurface.apply(to: window, style: style)
        }
    }
}
#endif
