import Foundation
import PurrdrAgentFeatures
import Testing

/// 離線佇列的 prompt 原文不進 UserDefaults(會進備份)，改存 Keychain 這類不進備份的位置(#575)。
/// 這裡用記憶體替身驗證遷移、重裝清理與背景寫入;真正的 Keychain adapter 只在 macOS CI 才跑得到。
@MainActor
@Suite("離線佇列的保護儲存")
struct ProtectedOfflineQueueStoreTests {
    final class MemoryBlobs: OfflineQueueBlobStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private var failing = false
        private var droppingWrites = false
        private var writeThreadFlags: [Bool] = []
        private var written: [String] = []
        var writeDelay: TimeInterval = 0

        var failsWrites: Bool {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }
        /// 寫入「成功」但讀不回來(讀回確認要擋下)。
        var dropsWrites: Bool {
            get { lock.withLock { droppingWrites } }
            set { lock.withLock { droppingWrites = newValue } }
        }
        var accounts: [String] { lock.withLock { items.keys.sorted() } }
        var anyWriteOnMainThread: Bool { lock.withLock { writeThreadFlags.contains(true) } }
        var writeCount: Int { lock.withLock { writeThreadFlags.count } }

        func seed(_ data: Data, account: String) { lock.withLock { items[account] = data } }
        func read(account: String) -> Data? { lock.withLock { items[account] } }
        func write(_ data: Data, account: String) throws {
            if writeDelay > 0 { Thread.sleep(forTimeInterval: writeDelay) }
            try lock.withLock {
                writeThreadFlags.append(Thread.isMainThread)
                if failing { throw CocoaError(.fileWriteUnknown) }
                if !droppingWrites { items[account] = data }
            }
        }
        func delete(account: String) { lock.withLock { items[account] = nil } }
        func deleteAll() { lock.withLock { items = [:] } }
    }

    final class MemoryLegacy: LegacyOfflineQueueSource, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private var initialized = false

        func seed(_ data: Data, host: String) { lock.withLock { items[host] = data } }
        func data(host: String) -> Data? { lock.withLock { items[host] } }
        func remove(host: String) { lock.withLock { items[host] = nil } }
        var hasAnyQueue: Bool { lock.withLock { !items.isEmpty } }
        var isInitialized: Bool { lock.withLock { initialized } }
        func markInitialized() { lock.withLock { initialized = true } }
        var hosts: [String] { lock.withLock { items.keys.sorted() } }
    }

    static let created = Date(timeIntervalSince1970: 1_794_614_400)

    /// 已初始化過的舊來源(一般的第二次以後啟動)。
    static func initializedLegacy() -> MemoryLegacy {
        let legacy = MemoryLegacy()
        legacy.markInitialized()
        return legacy
    }

    static func prompts(_ texts: String...) -> [QueuedPrompt] {
        texts.map { QueuedPrompt(text: $0, paneID: "w1:p6", workspaceID: "w1", sessionID: "s-1", createdAt: created) }
    }

    static func store(_ blobs: MemoryBlobs, _ legacy: MemoryLegacy) -> ProtectedOfflineQueueStore {
        ProtectedOfflineQueueStore(blobs: blobs, legacy: legacy)
    }

    // MARK: - 基本行為

    @Test("存進去再由新的 store 讀出(App 重開仍在)，內容原樣")
    func roundTrips() {
        let blobs = MemoryBlobs()
        let saved = Self.prompts("重開也在", "第二則")
        let first = Self.store(blobs, Self.initializedLegacy())
        first.save(saved, host: "demo")
        first.flush()

        #expect(Self.store(blobs, Self.initializedLegacy()).load(host: "demo") == saved)
    }

    @Test("存的當下馬上讀得到(背景還沒寫完也一樣)")
    func readsItsOwnWritesBeforeTheyLand() {
        let blobs = MemoryBlobs()
        blobs.writeDelay = 0.05
        let store = Self.store(blobs, Self.initializedLegacy())
        let saved = Self.prompts("剛存的")

        store.save(saved, host: "demo")

        #expect(store.load(host: "demo") == saved)
        store.flush()
    }

    @Test("存空陣列：刪掉儲存的內容(主機刪除時也是這個呼叫)")
    func savingEmptyDeletesStoredItem() {
        let blobs = MemoryBlobs()
        let store = Self.store(blobs, Self.initializedLegacy())
        store.save(Self.prompts("a"), host: "demo")
        store.flush()

        store.save([], host: "demo")
        store.flush()

        #expect(blobs.accounts.isEmpty)
        #expect(store.load(host: "demo").isEmpty)
    }

    @Test("每台主機各一份，刪一台不影響另一台")
    func hostsAreSeparate() {
        let blobs = MemoryBlobs()
        let store = Self.store(blobs, Self.initializedLegacy())
        store.save(Self.prompts("甲"), host: "a")
        store.save(Self.prompts("乙"), host: "b")
        store.save([], host: "a")
        store.flush()

        #expect(store.load(host: "a").isEmpty)
        #expect(store.load(host: "b").map(\.text) == ["乙"])
        #expect(blobs.accounts == ["b"])
    }

    @Test("存檔不再寫進舊的 UserDefaults")
    func savingNeverTouchesLegacy() {
        let legacy = Self.initializedLegacy()
        let store = Self.store(MemoryBlobs(), legacy)
        store.save(Self.prompts("機密"), host: "demo")
        store.flush()

        #expect(legacy.hosts.isEmpty)
    }

    // MARK: - 背景寫入

    @Test("寫入不在主執行緒")
    func writesHappenOffTheMainThread() {
        let blobs = MemoryBlobs()
        let store = Self.store(blobs, Self.initializedLegacy())
        store.save(Self.prompts("a"), host: "demo")
        store.flush()

        #expect(blobs.writeCount >= 1)
        #expect(!blobs.anyWriteOnMainThread)
    }

    @Test("連續變動：最後的狀態才是留下來的，而且多次變動會合併")
    func rapidChangesEndInTheLastState() {
        let blobs = MemoryBlobs()
        blobs.writeDelay = 0.01
        let store = Self.store(blobs, Self.initializedLegacy())
        for count in 1...30 {
            store.save(Self.prompts("第 \(count) 版"), host: "demo")
        }
        let final = Self.prompts("最後一版")
        store.save(final, host: "demo")
        store.flush()

        #expect(Self.store(blobs, Self.initializedLegacy()).load(host: "demo") == final)
        #expect(blobs.writeCount < 32)
    }

    @Test("連續變動最後是清空：最後的狀態是沒有項目")
    func rapidChangesEndingInEmptyLeaveNothing() {
        let blobs = MemoryBlobs()
        blobs.writeDelay = 0.01
        let store = Self.store(blobs, Self.initializedLegacy())
        for count in 1...10 {
            store.save(Self.prompts("第 \(count) 版"), host: "demo")
        }
        store.save([], host: "demo")
        store.flush()

        #expect(blobs.accounts.isEmpty)
    }

    // MARK: - 升級：從 UserDefaults 遷移

    @Test("升級：舊的 UserDefaults 資料遷移到新位置，舊的刪除，不被當成重裝清掉")
    func upgradeMigratesLegacyAndRemovesIt() throws {
        let blobs = MemoryBlobs()
        let legacy = MemoryLegacy()
        let old = Self.prompts("舊資料")
        legacy.seed(try JSONEncoder().encode(old), host: "demo")
        blobs.seed(Data("[]".utf8), account: "other")
        let store = Self.store(blobs, legacy)

        #expect(store.load(host: "demo") == old)
        store.flush()

        #expect(legacy.hosts.isEmpty)
        #expect(legacy.isInitialized)
        #expect(blobs.accounts == ["demo", "other"])
        #expect(Self.store(blobs, Self.initializedLegacy()).load(host: "demo") == old)
    }

    @Test("遷移：新位置寫入失敗，舊資料保留;下次載入再試，成功才刪")
    func migrationRetriesAfterFailure() throws {
        let blobs = MemoryBlobs()
        blobs.failsWrites = true
        let legacy = MemoryLegacy()
        let old = Self.prompts("舊資料")
        legacy.seed(try JSONEncoder().encode(old), host: "demo")
        let first = Self.store(blobs, legacy)

        #expect(first.load(host: "demo") == old)
        first.flush()
        #expect(legacy.hosts == ["demo"])

        blobs.failsWrites = false
        let second = Self.store(blobs, legacy)
        #expect(second.load(host: "demo") == old)
        second.flush()
        #expect(legacy.hosts.isEmpty)
        #expect(blobs.accounts == ["demo"])
    }

    @Test("遷移：讀回不一致就不刪舊資料")
    func migrationKeepsLegacyWhenReadBackDiffers() throws {
        let blobs = MemoryBlobs()
        blobs.dropsWrites = true
        let legacy = MemoryLegacy()
        legacy.seed(try JSONEncoder().encode(Self.prompts("舊資料")), host: "demo")
        let store = Self.store(blobs, legacy)

        _ = store.load(host: "demo")
        store.flush()

        #expect(legacy.hosts == ["demo"])
    }

    @Test("遷移可以重複執行：兩個 store 連續載入同一份舊資料，結果一致")
    func migrationIsRepeatable() throws {
        let blobs = MemoryBlobs()
        let legacy = MemoryLegacy()
        let old = Self.prompts("舊資料")
        legacy.seed(try JSONEncoder().encode(old), host: "demo")
        let first = Self.store(blobs, legacy)
        let second = Self.store(blobs, legacy)

        #expect(first.load(host: "demo") == old)
        #expect(second.load(host: "demo") == old)
        first.flush()
        second.flush()

        #expect(Self.store(blobs, Self.initializedLegacy()).load(host: "demo") == old)
        #expect(legacy.hosts.isEmpty)
    }

    @Test("新位置已有資料：以新的為準，並把殘留的舊資料刪掉")
    func existingProtectedDataWinsAndStaleLegacyIsRemoved() throws {
        let blobs = MemoryBlobs()
        let legacy = Self.initializedLegacy()
        let current = Self.prompts("新的")
        let writer = Self.store(blobs, Self.initializedLegacy())
        writer.save(current, host: "demo")
        writer.flush()
        legacy.seed(try JSONEncoder().encode(Self.prompts("殘留的舊資料")), host: "demo")

        #expect(Self.store(blobs, legacy).load(host: "demo") == current)
        #expect(legacy.hosts.isEmpty)
    }

    @Test("舊資料損毀：刪掉它，回空佇列")
    func corruptLegacyIsDropped() {
        let legacy = MemoryLegacy()
        legacy.seed(Data("not json".utf8), host: "demo")
        let store = Self.store(MemoryBlobs(), legacy)

        #expect(store.load(host: "demo").isEmpty)
        store.flush()
        #expect(legacy.hosts.isEmpty)
    }

    // MARK: - 全新安裝與重裝

    @Test("全新安裝：沒有標記也沒有舊資料，載入後設標記")
    func freshInstallMarksInitialized() {
        let legacy = MemoryLegacy()

        #expect(Self.store(MemoryBlobs(), legacy).load(host: "demo").isEmpty)

        #expect(legacy.isInitialized)
    }

    @Test("重裝：沒有標記又沒有舊資料，Keychain 殘留的項目先清掉")
    func reinstallClearsStaleProtectedItems() {
        let blobs = MemoryBlobs()
        blobs.seed(Data("[]".utf8), account: "demo")
        blobs.seed(Data("[]".utf8), account: "other")
        let legacy = MemoryLegacy()
        let store = Self.store(blobs, legacy)

        #expect(store.load(host: "demo").isEmpty)

        #expect(blobs.accounts.isEmpty)
        #expect(legacy.isInitialized)
    }

    @Test("重裝後第一次是先存再讀:清理在寫入之前，新資料不會被清掉")
    func reinstallClearsBeforeFirstSave() {
        let blobs = MemoryBlobs()
        blobs.seed(Data("[]".utf8), account: "stale")
        let store = Self.store(blobs, MemoryLegacy())
        let saved = Self.prompts("新的")

        store.save(saved, host: "demo")
        store.flush()

        #expect(blobs.accounts == ["demo"])
        #expect(Self.store(blobs, Self.initializedLegacy()).load(host: "demo") == saved)
    }

    @Test("一般的第二次啟動：已有標記，不清 Keychain")
    func relaunchKeepsProtectedItems() {
        let blobs = MemoryBlobs()
        let saved = Self.prompts("留著")
        let first = Self.store(blobs, Self.initializedLegacy())
        first.save(saved, host: "demo")
        first.flush()

        #expect(Self.store(blobs, Self.initializedLegacy()).load(host: "demo") == saved)
        #expect(blobs.accounts == ["demo"])
    }
}
