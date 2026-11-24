import Foundation

/// iPad 對話右側 Inspector 要不要顯示的本機偏好(#521)。只在這支裝置、不同步;沒存過時預設顯示。
@MainActor
public protocol InspectorVisibilityStore: AnyObject {
    func load() -> Bool
    func save(_ isShown: Bool)
}

/// 只在記憶體:測試與 UI 測試用。
@MainActor
public final class InMemoryInspectorVisibilityStore: InspectorVisibilityStore {
    private var isShown: Bool

    public init(isShown: Bool = true) {
        self.isShown = isShown
    }

    public func load() -> Bool { isShown }
    public func save(_ isShown: Bool) { self.isShown = isShown }
}

/// 存在 `UserDefaults`(key `conversation.inspectorShown`)。
@MainActor
public final class UserDefaultsInspectorVisibilityStore: InspectorVisibilityStore {
    public static let key = "conversation.inspectorShown"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Bool { defaults.object(forKey: Self.key) as? Bool ?? true }
    public func save(_ isShown: Bool) { defaults.set(isShown, forKey: Self.key) }
}
