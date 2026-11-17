import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 觸覺回饋的種類(行為規格 F20:選擇、結果的成功／錯誤;捲動時永不觸覺)。
public enum HapticFeedback: Sendable, Equatable {
    /// 選擇(點了一個選項)。
    case selection
    case success
    case error
}

/// 觸覺回饋的單一入口(畫面 model 注入;測試記錄播放了什麼)。
@MainActor
public protocol Haptics: AnyObject {
    func play(_ feedback: HapticFeedback)
}

/// 不播放任何觸覺(預設值、`swift test`)。
public final class SilentHaptics: Haptics {
    public init() {}
    public func play(_ feedback: HapticFeedback) {}
}

/// 觸覺設定(HIG 20.7:haptic 可關閉)。
public enum HapticSettings {
    /// `@AppStorage` key,預設開啟。
    public static let enabledKey = "haptics.enabled"

    package static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

#if canImport(UIKit)
/// 系統觸覺：選擇用 `UISelectionFeedbackGenerator`,結果用 notification haptic(HIG 20.7)。尊重設定。
public final class SystemHaptics: Haptics {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func play(_ feedback: HapticFeedback) {
        guard HapticSettings.isEnabled(defaults) else { return }
        switch feedback {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
#endif
