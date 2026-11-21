import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Testing

/// 對話的本機 SQLite 快取(#356):app 重開後仍在，有上限，刪除主機時清掉，只存這支裝置。一律用暫存資料庫。
@Suite("對話 SQLite 快取")
struct SQLiteConversationCacheTests {
    static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "purrdr-cache-\(UUID().uuidString)").appending(path: "conversations.sqlite")
    }

    static func conversation(session: String = "s1", messages: Int = 3, textBytes: Int = 20) -> CachedConversation {
        CachedConversation(
            sessionID: session,
            messages: (0..<messages).map {
                TranscriptMessage(id: "m\($0)", role: .assistant, date: nil, parts: [.text(String(repeating: "x", count: textBytes))])
            },
            metadata: TranscriptMetadata(model: "claude-test", contextTokens: 10, effort: nil),
            path: "/t/\(session).jsonl", cursor: 1234, windowStart: 56)
    }

    @Test("存了再讀：訊息、游標與 metadata 原樣回來")
    func roundTrip() async {
        let cache = SQLiteConversationCache(file: Self.temporaryFile())
        let saved = Self.conversation()

        await cache.save(saved, chatKey: "h1/w1:p1")

        #expect(await cache.load(chatKey: "h1/w1:p1") == saved)
        #expect(await cache.load(chatKey: "h1/w1:p2") == nil)
    }

    @Test("同一個聊天再存會覆蓋")
    func saveReplaces() async {
        let cache = SQLiteConversationCache(file: Self.temporaryFile())
        await cache.save(Self.conversation(messages: 3), chatKey: "k")
        await cache.save(Self.conversation(messages: 5), chatKey: "k")

        #expect(await cache.load(chatKey: "k")?.messages.count == 5)
    }

    @Test("app 重開(換一個實例開同一個檔案)之後還在")
    func survivesReopen() async {
        let file = Self.temporaryFile()
        await SQLiteConversationCache(file: file).save(Self.conversation(), chatKey: "k")

        #expect(await SQLiteConversationCache(file: file).load(chatKey: "k") == Self.conversation())
    }

    @Test("remove 與依主機清除：只動前綴相符的聊天(前綴裡的 % 與 _ 不當萬用字元)")
    func removal() async {
        let cache = SQLiteConversationCache(file: Self.temporaryFile())
        for key in ["h_1/a", "h_1/b", "hX1/a", "h%/a", "other/a"] { await cache.save(Self.conversation(), chatKey: key) }

        await cache.remove(chatKey: "h_1/a")
        #expect(await cache.load(chatKey: "h_1/a") == nil)
        #expect(await cache.load(chatKey: "h_1/b") != nil)

        await cache.removeAll(chatKeyPrefix: "h_1/")
        #expect(await cache.load(chatKey: "h_1/b") == nil)
        #expect(await cache.load(chatKey: "hX1/a") != nil)

        await cache.removeAll(chatKeyPrefix: "h%/")
        #expect(await cache.load(chatKey: "h%/a") == nil)
        #expect(await cache.load(chatKey: "other/a") != nil)
    }

    @Test("聊天數超過上限：丟掉最久沒用的")
    func evictsLeastRecentlyUsedByCount() async {
        let tick = Ticker()
        let cache = SQLiteConversationCache(
            file: Self.temporaryFile(), limits: .init(maxChats: 3, maxTotalBytes: 1 << 30, maxChatBytes: 1 << 30), now: { tick.next() })
        for key in ["a", "b", "c"] { await cache.save(Self.conversation(), chatKey: key) }
        _ = await cache.load(chatKey: "a")

        await cache.save(Self.conversation(), chatKey: "d")

        #expect(await cache.load(chatKey: "b") == nil)
        for key in ["a", "c", "d"] { #expect(await cache.load(chatKey: key) != nil) }
    }

    @Test("總大小超過上限：從最久沒用的開始丟，直到放得下")
    func evictsByTotalBytes() async {
        let tick = Ticker()
        let big = Self.conversation(messages: 1, textBytes: 4_000)
        let cache = SQLiteConversationCache(
            file: Self.temporaryFile(), limits: .init(maxChats: 100, maxTotalBytes: 10_000, maxChatBytes: 1 << 30), now: { tick.next() })
        for key in ["a", "b", "c"] { await cache.save(big, chatKey: key) }

        #expect(await cache.load(chatKey: "a") == nil)
        #expect(await cache.load(chatKey: "b") != nil)
        #expect(await cache.load(chatKey: "c") != nil)
    }

    @Test("單一聊天超過大小上限：不存，舊的也移除(避免顯示過期內容)")
    func oversizedChatIsNotStored() async {
        let cache = SQLiteConversationCache(
            file: Self.temporaryFile(), limits: .init(maxChats: 100, maxTotalBytes: 1 << 30, maxChatBytes: 2_000))
        await cache.save(Self.conversation(messages: 1, textBytes: 10), chatKey: "k")

        await cache.save(Self.conversation(messages: 1, textBytes: 5_000), chatKey: "k")

        #expect(await cache.load(chatKey: "k") == nil)
    }

    @Test("壞掉的資料庫檔案：當作沒有快取並重建，之後照常使用")
    func recoversFromCorruptFile() async throws {
        let file = Self.temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database, just garbage bytes".utf8).write(to: file)
        let cache = SQLiteConversationCache(file: file)

        #expect(await cache.load(chatKey: "k") == nil)
        await cache.save(Self.conversation(), chatKey: "k")
        #expect(await cache.load(chatKey: "k") != nil)
    }

    @Test("資料庫檔案與資料夾排除 iCloud 備份")
    func databaseIsExcludedFromBackup() async throws {
        let file = Self.temporaryFile()
        let cache = SQLiteConversationCache(file: file)
        await cache.save(Self.conversation(), chatKey: "k")

        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}

/// 單調遞增的假時鐘(最近使用的排序不靠真實時間)。
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func next() -> Double { lock.withLock { value += 1; return value } }
}
