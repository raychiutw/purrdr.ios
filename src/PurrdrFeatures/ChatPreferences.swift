import Foundation

/// 每個聊天在本機的偏好：釘選時間與靜音(#37「釘選、靜音…存本機」)。
///
/// 以 Agent 的 session id 為 key(聊天綁定 session,herdr 回收 pane 編號時不會套到別人的聊天上)。
/// 沒有 session 的 Agent 不提供釘選與靜音(行為規格 F2.7)。
public struct ChatPreferences: Codable, Equatable, Sendable {
    /// session id → 釘選時間。「已釘選」群組依釘選時間排序(#41)。
    public var pinned: [String: Date]
    public var muted: Set<String>

    public init(pinned: [String: Date] = [:], muted: Set<String> = []) {
        self.pinned = pinned
        self.muted = muted
    }
}

/// 聊天偏好的本機存放處。
@MainActor
public protocol ChatPreferencesStore: AnyObject {
    func load() -> ChatPreferences
    func save(_ preferences: ChatPreferences)
}

/// 只在記憶體裡的存放處：測試與 UI 測試用(每次啟動都從空白開始)。
@MainActor
public final class InMemoryChatPreferencesStore: ChatPreferencesStore {
    private var preferences: ChatPreferences

    public init(_ preferences: ChatPreferences = ChatPreferences()) {
        self.preferences = preferences
    }

    public func load() -> ChatPreferences { preferences }
    public func save(_ preferences: ChatPreferences) { self.preferences = preferences }
}

/// 存在 `UserDefaults` 的存放處(只在這支裝置，不同步)。
@MainActor
public final class UserDefaultsChatPreferencesStore: ChatPreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "chatPreferences") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> ChatPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(ChatPreferences.self, from: data) else { return ChatPreferences() }
        return preferences
    }

    public func save(_ preferences: ChatPreferences) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: key)
    }
}
