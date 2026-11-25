import Foundation

/// 存放離線佇列內容的位置(Seam:正式是 Keychain,測試是記憶體);內容是 JSON。
public protocol OfflineQueueBlobStore: AnyObject, Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String)
}

/// 舊版存在 `UserDefaults` 的資料(只讀取與刪除，用來遷移)。
public protocol LegacyOfflineQueueSource: Sendable {
    func data(host: String) -> Data?
    func remove(host: String)
}

/// 離線佇列存在不進備份的位置(正式是 Keychain)。
///
/// - 變動先記在記憶體，由背景序列合併後寫入(同一台主機只寫最後的狀態);讀取先看還沒寫出的變動。
/// - 重裝殘留(App 刪除後 Keychain 項目還在)由啟動時的 `ReinstallGuard` 統一清理，這裡不處理。
/// - 遷移:新位置寫入並讀回一致，才刪舊的;失敗保留舊資料，下次載入再試。
@MainActor
public final class ProtectedOfflineQueueStore: OfflineQueueStore {
    public nonisolated static let accountPrefix = "offlineQueue."

    private let blobs: any OfflineQueueBlobStore
    private let legacy: any LegacyOfflineQueueSource
    private let writer: OfflineQueueWriter

    public init(blobs: any OfflineQueueBlobStore, legacy: any LegacyOfflineQueueSource) {
        self.blobs = blobs
        self.legacy = legacy
        writer = OfflineQueueWriter(blobs: blobs, legacy: legacy)
    }

    /// 正式用:Keychain(僅此裝置、不進備份)加上舊的 `UserDefaults` 遷移來源。
    public static func system(defaults: UserDefaults = .standard) -> ProtectedOfflineQueueStore {
        ProtectedOfflineQueueStore(blobs: SystemOfflineQueueBlobStore.make(), legacy: UserDefaultsLegacyOfflineQueue(defaults: defaults))
    }

    public func load(host: String) -> [QueuedPrompt] {
        switch writer.pending(host: host) {
        case .write(let data)?: return decode(data)
        case .delete?: return []
        case nil: break
        }
        let legacyData = legacy.data(host: host)
        if let stored = blobs.read(account: host) {
            if legacyData != nil { legacy.remove(host: host) }
            return decode(stored)
        }
        guard let legacyData else { return [] }
        guard let migrated = try? JSONDecoder().decode([QueuedPrompt].self, from: legacyData) else {
            legacy.remove(host: host)
            return []
        }
        writer.submit(.write(legacyData), host: host)
        return migrated
    }

    public func save(_ prompts: [QueuedPrompt], host: String) {
        if prompts.isEmpty {
            writer.submit(.delete, host: host)
        } else if let data = try? JSONEncoder().encode(prompts) {
            writer.submit(.write(data), host: host)
        }
    }

    /// 等背景寫入全部完成(測試、App 結束前)。
    public func flush() {
        writer.flush()
    }

    private func decode(_ data: Data) -> [QueuedPrompt] {
        (try? JSONDecoder().decode([QueuedPrompt].self, from: data)) ?? []
    }
}

/// 背景序列寫入:同一台主機的多次變動合併成最後一次;寫入成功且讀回一致，才刪舊版資料。
final class OfflineQueueWriter: @unchecked Sendable {
    enum Operation: Equatable {
        case write(Data)
        case delete
    }

    private let blobs: any OfflineQueueBlobStore
    private let legacy: any LegacyOfflineQueueSource
    private let queue = DispatchQueue(label: "purrdr.offline-queue-writer")
    private let lock = NSLock()
    private var operations: [String: (operation: Operation, version: Int)] = [:]
    private var nextVersion = 0
    private var isDraining = false

    init(blobs: any OfflineQueueBlobStore, legacy: any LegacyOfflineQueueSource) {
        self.blobs = blobs
        self.legacy = legacy
    }

    /// 還沒寫出的最新變動。
    func pending(host: String) -> Operation? {
        lock.withLock { operations[host]?.operation }
    }

    func submit(_ operation: Operation, host: String) {
        let shouldStart: Bool = lock.withLock {
            nextVersion += 1
            operations[host] = (operation, nextVersion)
            if isDraining { return false }
            isDraining = true
            return true
        }
        if shouldStart { queue.async { self.drain() } }
    }

    func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            let batch: [(host: String, operation: Operation, version: Int)] = lock.withLock {
                operations.map { ($0.key, $0.value.operation, $0.value.version) }
            }
            if batch.isEmpty {
                let finished: Bool = lock.withLock {
                    if operations.isEmpty { isDraining = false }
                    return operations.isEmpty
                }
                if finished { return }
                continue
            }
            for item in batch {
                apply(item.operation, host: item.host)
                lock.withLock {
                    if operations[item.host]?.version == item.version { operations[item.host] = nil }
                }
            }
        }
    }

    private func apply(_ operation: Operation, host: String) {
        switch operation {
        case .write(let data):
            do {
                try blobs.write(data, account: host)
            } catch {
                return
            }
            if blobs.read(account: host) == data { legacy.remove(host: host) }
        case .delete:
            blobs.delete(account: host)
            legacy.remove(host: host)
        }
    }
}

/// 舊版的來源:`UserDefaults`(每台主機一個 key)。
public struct UserDefaultsLegacyOfflineQueue: LegacyOfflineQueueSource, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(host: String) -> Data? { defaults.data(forKey: ProtectedOfflineQueueStore.accountPrefix + host) }
    public func remove(host: String) { defaults.removeObject(forKey: ProtectedOfflineQueueStore.accountPrefix + host) }
}

/// 記憶體版(沒有 Keychain 的平台、測試)。
public final class InMemoryOfflineQueueBlobStore: OfflineQueueBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(account: String) -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) { lock.withLock { items[account] = nil } }
}

public enum SystemOfflineQueueBlobStore {
    /// Apple 平台是 Keychain 版,其他平台是記憶體版。
    public static func make() -> any OfflineQueueBlobStore {
        #if canImport(Security)
        KeychainOfflineQueueBlobStore()
        #else
        InMemoryOfflineQueueBlobStore()
        #endif
    }
}

#if canImport(Security)
import Security

/// Keychain 的 SecItem 介面(Seam:正式用 `SystemOfflineQueueKeychain`,測試用假實作)。
public protocol OfflineQueueKeychainAPI: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func delete(_ query: [String: Any]) -> OSStatus
}

/// 系統 Keychain。
public struct SystemOfflineQueueKeychain: OfflineQueueKeychainAPI {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    public func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    public func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Keychain 版的儲存:service `purrdr.offlineQueue`、account 是主機 id,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 且不同步(不進備份、不上 iCloud 鑰匙圈)。
public final class KeychainOfflineQueueBlobStore: OfflineQueueBlobStore, @unchecked Sendable {
    public static let service = "purrdr.offlineQueue"

    private let keychain: any OfflineQueueKeychainAPI

    public init(keychain: any OfflineQueueKeychainAPI = SystemOfflineQueueKeychain()) {
        self.keychain = keychain
    }

    private func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func read(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(request)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let updateStatus = keychain.update(query(account: account), [kSecValueData as String: data])
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus)) }
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let addStatus = keychain.add(attributes)
        guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
    }

    public func delete(account: String) {
        _ = keychain.delete(query(account: account))
    }
}
#endif
