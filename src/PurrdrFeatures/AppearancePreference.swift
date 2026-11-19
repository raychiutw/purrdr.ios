import Foundation

/// app 內的外觀設定(#246):自動(依系統)／淺色／深色。
public enum AppearancePreference: String, CaseIterable, Sendable {
    case automatic
    case light
    case dark

    /// `@AppStorage` key。
    public static let storageKey = "appearance"

    public static func stored(in defaults: UserDefaults) -> AppearancePreference {
        defaults.string(forKey: storageKey).flatMap(AppearancePreference.init(rawValue:)) ?? .automatic
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
