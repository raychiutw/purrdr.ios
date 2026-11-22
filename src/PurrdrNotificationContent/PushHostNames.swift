import Foundation

/// 推播通知的副標題(主機名稱)補上規則(#431)。
///
/// 後台永遠不知道主機名稱:通知到達手機後,Notification Service Extension 依 payload 根層的 `pairing`
/// (配對密鑰雜湊)查 App Group 裡的對應表,把主機名稱填進副標題。
public enum PushNotificationEnrichment {
    /// 補完的通知內容:標題由後台組好(`workspace · Tab` 或只有 workspace),這裡不動它。
    public struct Content: Equatable, Sendable {
        public var title: String
        public var subtitle: String

        public init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// payload + 對應表 → 通知內容。查不到(沒有 `pairing`、對應表沒有那一組、名稱是空的)就原樣回傳。
    public static func enriched(
        title: String, subtitle: String, userInfo: [AnyHashable: Any], hostNames: [String: String]
    ) -> Content {
        guard let pairing = userInfo["pairing"] as? String, let name = hostNames[pairing]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return Content(title: title, subtitle: subtitle) }
        return Content(title: title, subtitle: name)
    }
}

/// 「配對雜湊 → 主機顯示名稱」對應表(不含金鑰或權杖),app 寫、extension 讀。
public enum PushHostNameMap {
    /// 由配對(主機 id → 雜湊)與主機名稱(主機 id → 名稱)組出對應表;沒有名稱的配對略過。
    public static func make(pairings: [String: String], hostNames: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        for (host, keyHash) in pairings {
            if let name = hostNames[host] { map[keyHash] = name }
        }
        return map
    }
}

/// 共用儲存(正式是 App Group 的 `UserDefaults`)。
public protocol PushHostNameSharing: Sendable {
    func save(_ names: [String: String])
    func load() -> [String: String]
}

/// 存在 `UserDefaults` 套件(正式是 App Group)的對應表。
public struct UserDefaultsPushHostNames: PushHostNameSharing, @unchecked Sendable {
    public static let appGroupID = "group.com.raychiu.purrdr"
    static let key = "push.hostNames"
    private let defaults: UserDefaults?

    public init(suiteName: String = UserDefaultsPushHostNames.appGroupID) {
        defaults = UserDefaults(suiteName: suiteName)
    }

    public func save(_ names: [String: String]) {
        defaults?.set(names, forKey: Self.key)
    }

    public func load() -> [String: String] {
        defaults?.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
