import Foundation
import Observation

/// 歡迎頁看過了沒有。
@MainActor
public protocol WelcomeStore: AnyObject {
    var hasSeen: Bool { get set }
}

@MainActor
public final class InMemoryWelcomeStore: WelcomeStore {
    public var hasSeen: Bool

    public init(hasSeen: Bool = false) {
        self.hasSeen = hasSeen
    }
}

@MainActor
public final class UserDefaultsWelcomeStore: WelcomeStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let key = "welcomeSeen"

    public var hasSeen: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// 第一次開啟的歡迎頁(#34;HIG Onboarding:短、可跳過，跳過後不再出現，但在設定頁找得到)。
///
/// 全 app 一份;第一個開出它的視窗就算看過(關掉 app 或開第二個視窗都不會再跳出)。
@MainActor
public final class WelcomeModel {
    private let store: any WelcomeStore

    public init(store: any WelcomeStore) {
        self.store = store
    }

    /// 第一次啟動時回傳 `true`(並記成看過);之後一律 `false`。
    func takeFirstLaunch() -> Bool {
        guard !store.hasSeen else { return false }
        store.hasSeen = true
        return true
    }
}
