import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// UI 測試用:把字級類別套到 app 所有視窗(`UIWindow.traitOverrides`),不必重啟就能量 AX5。
/// 只有 `purrdr://testing-content-size` 測試連結會呼叫(`-uiTesting` 才開),正式 app 不會走到。
@MainActor
enum TestingContentSize {
    /// `light`／`dark` 套到所有視窗的 `overrideUserInterfaceStyle`;`nil` 跟隨系統。
    static func apply(appearance: String?) {
        #if canImport(UIKit)
        let style: UIUserInterfaceStyle = switch appearance {
        case "light": .light
        case "dark": .dark
        default: .unspecified
        }
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            window.overrideUserInterfaceStyle = style
        }
        #endif
    }

    static func apply(_ category: String?) {
        #if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if let category {
                window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(rawValue: category)
            } else {
                window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
            }
        }
        #endif
    }
}
