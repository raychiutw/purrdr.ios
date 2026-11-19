import SwiftUI

extension AppearancePreference {
    /// `nil` 跟隨系統。
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// 套用設定頁的外觀(#246)。每個視窗的根畫面都要掛;設定改了立即生效。
    public func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.automatic

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}
