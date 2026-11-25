import Foundation
import PurrdrCore

/// 把主機寫入的同意存在 UserDefaults(行為規格 F18:同意持久化，移除主機時清除)。
public final class UserDefaultsHostWriteConsentStore: HostWriteConsentStore, @unchecked Sendable {  // UserDefaults 執行緒安全但沒標 Sendable;讀改寫由 `lock` 保護
    static let key = "purrdr.hostWriteConsent"
    private let defaults: UserDefaults
    /// `UserDefaults` 本身執行緒安全,這把鎖讓「讀 → 改 → 寫」整段不被別的執行緒插進來。
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isGranted(_ feature: String, host: String) -> Bool {
        lock.withLock { consents[host]?.contains(feature) == true }
    }

    public func grant(_ feature: String, host: String) {
        update { $0[host, default: []].insert(feature) }
    }

    public func revoke(_ feature: String, host: String) {
        update { $0[host]?.remove(feature) }
    }

    public func revokeAll(host: String) {
        update { $0[host] = nil }
    }

    /// 主機 id → 已同意的功能。
    private var consents: [String: Set<String>] {
        (defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]).mapValues(Set.init)
    }

    private func update(_ change: (inout [String: Set<String>]) -> Void) {
        lock.withLock {
            var value = consents
            change(&value)
            defaults.set(value.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }, forKey: Self.key)
        }
    }
}
