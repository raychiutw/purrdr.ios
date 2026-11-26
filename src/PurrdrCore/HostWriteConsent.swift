import Foundation
import Synchronization

/// 使用者對「某台主機上的某個寫入功能」的同意(ADR-0002:每台主機個別同意)。
///
/// 同意存在 app 端(持久化);主機上有沒有安裝由 `ReversibleHostWrite` 的安裝紀錄判斷。
/// 移除主機時呼叫 `revokeAll(host:)` 清除該主機的所有同意。
public protocol HostWriteConsentStore: AnyObject, Sendable {
    func isGranted(_ feature: String, host: String) -> Bool
    func grant(_ feature: String, host: String)
    func revoke(_ feature: String, host: String)
    func revokeAll(host: String)
}

/// 只存在記憶體的同意(測試、UI 測試、Demo 用)。
public final class InMemoryHostWriteConsentStore: HostWriteConsentStore, Sendable {
    private let granted = Mutex<Set<String>>([])

    public init() {}

    public func isGranted(_ feature: String, host: String) -> Bool { granted.withLock { $0.contains(Self.key(feature, host)) } }
    public func grant(_ feature: String, host: String) { _ = granted.withLock { $0.insert(Self.key(feature, host)) } }
    public func revoke(_ feature: String, host: String) { _ = granted.withLock { $0.remove(Self.key(feature, host)) } }
    public func revokeAll(host: String) { granted.withLock { $0 = $0.filter { !$0.hasPrefix(host + "\u{0}") } } }

    private static func key(_ feature: String, _ host: String) -> String { host + "\u{0}" + feature }
}
