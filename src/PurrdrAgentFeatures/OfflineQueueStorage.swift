import Foundation

/// 存放離線佇列內容的位置(Seam:正式是 Keychain,測試是記憶體);內容是 JSON。
public protocol OfflineQueueBlobStore: AnyObject, Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String)
    /// 刪掉所有離線佇列項目(重裝殘留清理)。
    func deleteAll()
}

/// 舊版存在 `UserDefaults` 的資料,以及「已初始化」標記(只讀取與刪除，用來遷移與判斷重裝)。
public protocol LegacyOfflineQueueSource: Sendable {
    func data(host: String) -> Data?
    func remove(host: String)
    /// 舊版有沒有任何一台主機的佇列資料(有代表是升級,不是全新安裝或重裝)。
    var hasAnyQueue: Bool { get }
    /// 新版儲存是否已初始化過(App 刪除時 `UserDefaults` 一起消失，Keychain 不會)。
    var isInitialized: Bool { get }
    func markInitialized()
}

/// 離線佇列存在不進備份的位置(正式是 Keychain)。
///
/// - 變動先記在記憶體，由背景序列合併後寫入(同一台主機只寫最後的狀態);讀取先看還沒寫出的變動。
/// - 第一次載入:`UserDefaults` 沒有已初始化標記又沒有舊佇列資料(全新安裝或重裝)，先清掉殘留的項目;升級的使用者把舊資料遷移過來。
/// - 遷移:新位置寫入並讀回一致，才刪舊的;失敗保留舊資料，下次載入再試。
@MainActor
public final class ProtectedOfflineQueueStore: OfflineQueueStore {
    public nonisolated static let accountPrefix = "offlineQueue."

    private let blobs: any OfflineQueueBlobStore
    private let legacy: any LegacyOfflineQueueSource
    private var isPrepared = false

    public init(blobs: any OfflineQueueBlobStore, legacy: any LegacyOfflineQueueSource) {
        self.blobs = blobs
        self.legacy = legacy
    }

    /// 正式用:Keychain(僅此裝置、不進備份)加上舊的 `UserDefaults` 遷移來源。
    public static func system(defaults: UserDefaults = .standard) -> ProtectedOfflineQueueStore {
        ProtectedOfflineQueueStore(blobs: SystemOfflineQueueBlobStore.make(), legacy: UserDefaultsLegacyOfflineQueue(defaults: defaults))
    }

    public func load(host: String) -> [QueuedPrompt] { [] }
    public func save(_ prompts: [QueuedPrompt], host: String) {}

    /// 等背景寫入全部完成(測試、App 結束前)。
    public func flush() {}
}

/// 舊版的來源:`UserDefaults`(每台主機一個 key)。
public struct UserDefaultsLegacyOfflineQueue: LegacyOfflineQueueSource, @unchecked Sendable {
    public static let initializedKey = "purrdr.offlineQueueStoreInitialized"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(host: String) -> Data? { defaults.data(forKey: ProtectedOfflineQueueStore.accountPrefix + host) }
    public func remove(host: String) { defaults.removeObject(forKey: ProtectedOfflineQueueStore.accountPrefix + host) }
    public var hasAnyQueue: Bool {
        defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(ProtectedOfflineQueueStore.accountPrefix) }
    }
    public var isInitialized: Bool { defaults.bool(forKey: Self.initializedKey) }
    public func markInitialized() { defaults.set(true, forKey: Self.initializedKey) }
}

/// 記憶體版(沒有 Keychain 的平台、測試)。
public final class InMemoryOfflineQueueBlobStore: OfflineQueueBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(account: String) -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) { lock.withLock { items[account] = nil } }
    public func deleteAll() { lock.withLock { items = [:] } }
}

public enum SystemOfflineQueueBlobStore {
    /// Apple 平台是 Keychain 版,其他平台是記憶體版。
    public static func make() -> any OfflineQueueBlobStore {
        InMemoryOfflineQueueBlobStore()
    }
}
