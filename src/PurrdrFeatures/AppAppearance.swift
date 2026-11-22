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
        // 頁面底色:深色是提亮的 #1C1C1E(#379,見 `AppSurface`);畫面自己沒有底色的地方(對話、檔案)靠這一層。
        content
            .background { AppSurface.page.ignoresSafeArea() }
            .background { WindowAppearanceApplier(style: appearance.userInterfaceStyle) }
        #else
        content.preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(iOS)
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
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
#endif
