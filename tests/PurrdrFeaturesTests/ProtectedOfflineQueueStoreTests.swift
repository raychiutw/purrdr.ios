import Foundation
import PurrdrAgentFeatures
import Testing

/// 離線佇列的 prompt 原文不進 UserDefaults(會進備份)，改存 Keychain 這類不進備份的位置(#575)。
/// 這裡用記憶體替身驗證遷移與行為;真正的 Keychain adapter 只在 macOS CI 才跑得到。
@MainActor
@Suite("離線佇列的保護儲存")
struct ProtectedOfflineQueueStoreTests {
    final class MemoryBlobs: OfflineQueueBlobStore, @unchecked Sendable {
        var items: [String: Data] = [:]
        var failsWrites = false
        func read(account: String) -> Data? { items[account] }
        func write(_ data: Data, account: String) throws {
            if failsWrites { throw CocoaError(.fileWriteUnknown) }
            items[account] = data
        }
        func delete(account: String) { items[account] = nil }
    }

    final class MemoryLegacy: LegacyOfflineQueueSource, @unchecked Sendable {
        var items: [String: Data] = [:]
        func data(host: String) -> Data? { items[host] }
        func remove(host: String) { items[host] = nil }
    }

    static let created = Date(timeIntervalSince1970: 1_794_614_400)

    static func prompts(_ texts: String...) -> [QueuedPrompt] {
        texts.map { QueuedPrompt(text: $0, paneID: "w1:p6", workspaceID: "w1", sessionID: "s-1", createdAt: created) }
    }

    @Test("存進去再由新的 store 讀出(App 重開仍在)，內容原樣")
    func roundTrips() {
        let blobs = MemoryBlobs()
        let saved = Self.prompts("重開也在", "第二則")
        ProtectedOfflineQueueStore(blobs: blobs, legacy: MemoryLegacy()).save(saved, host: "demo")

        let loaded = ProtectedOfflineQueueStore(blobs: blobs, legacy: MemoryLegacy()).load(host: "demo")

        #expect(loaded == saved)
    }

    @Test("存空陣列：刪掉儲存的內容")
    func savingEmptyDeletesStoredItem() {
        let blobs = MemoryBlobs()
        let store = ProtectedOfflineQueueStore(blobs: blobs, legacy: MemoryLegacy())
        store.save(Self.prompts("a"), host: "demo")

        store.save([], host: "demo")

        #expect(blobs.items.isEmpty)
        #expect(store.load(host: "demo").isEmpty)
    }

    @Test("每台主機各一份")
    func hostsAreSeparate() {
        let store = ProtectedOfflineQueueStore(blobs: MemoryBlobs(), legacy: MemoryLegacy())
        store.save(Self.prompts("甲"), host: "a")
        store.save(Self.prompts("乙"), host: "b")

        #expect(store.load(host: "a").map(\.text) == ["甲"])
        #expect(store.load(host: "b").map(\.text) == ["乙"])
    }

    @Test("第一次載入：舊的 UserDefaults 資料遷移到新位置，舊的刪除")
    func migratesLegacyAndRemovesIt() throws {
        let blobs = MemoryBlobs()
        let legacy = MemoryLegacy()
        let old = Self.prompts("舊資料")
        legacy.items["demo"] = try JSONEncoder().encode(old)
        let store = ProtectedOfflineQueueStore(blobs: blobs, legacy: legacy)

        #expect(store.load(host: "demo") == old)

        #expect(legacy.items["demo"] == nil)
        #expect(ProtectedOfflineQueueStore(blobs: blobs, legacy: MemoryLegacy()).load(host: "demo") == old)
    }

    @Test("新位置寫入失敗：舊資料不刪(下次再遷移)，這次仍讀得到")
    func keepsLegacyWhenMigrationWriteFails() throws {
        let blobs = MemoryBlobs()
        blobs.failsWrites = true
        let legacy = MemoryLegacy()
        let old = Self.prompts("舊資料")
        legacy.items["demo"] = try JSONEncoder().encode(old)

        let loaded = ProtectedOfflineQueueStore(blobs: blobs, legacy: legacy).load(host: "demo")

        #expect(loaded == old)
        #expect(legacy.items["demo"] != nil)
    }

    @Test("新位置已有資料：以新的為準，並把殘留的舊資料刪掉")
    func existingProtectedDataWinsAndStaleLegacyIsRemoved() throws {
        let blobs = MemoryBlobs()
        let legacy = MemoryLegacy()
        let current = Self.prompts("新的")
        ProtectedOfflineQueueStore(blobs: blobs, legacy: MemoryLegacy()).save(current, host: "demo")
        legacy.items["demo"] = try JSONEncoder().encode(Self.prompts("殘留的舊資料"))

        #expect(ProtectedOfflineQueueStore(blobs: blobs, legacy: legacy).load(host: "demo") == current)
        #expect(legacy.items["demo"] == nil)
    }

    @Test("舊資料損毀：刪掉它，回空佇列")
    func corruptLegacyIsDropped() {
        let legacy = MemoryLegacy()
        legacy.items["demo"] = Data("not json".utf8)

        #expect(ProtectedOfflineQueueStore(blobs: MemoryBlobs(), legacy: legacy).load(host: "demo").isEmpty)
        #expect(legacy.items["demo"] == nil)
    }

    @Test("存檔不再寫進舊的 UserDefaults")
    func savingNeverTouchesLegacy() {
        let legacy = MemoryLegacy()
        ProtectedOfflineQueueStore(blobs: MemoryBlobs(), legacy: legacy).save(Self.prompts("機密"), host: "demo")

        #expect(legacy.items.isEmpty)
    }
}
