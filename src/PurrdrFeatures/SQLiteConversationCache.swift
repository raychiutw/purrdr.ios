import Foundation
import PurrdrAgentFeatures
import SQLite3

/// 對話的本機磁碟快取(#356):app 重開、從推播冷啟動打開聊天時，先從這裡顯示最近的訊息，再背景和主機同步。
///
/// 用系統的 libsqlite3(薄包裝，不加第三方套件)。每個聊天一列：key(主機 × pane)、整個 `CachedConversation`
/// 編成 JSON、大小與最近使用時間。有三道上限(`Limits`):聊天數、總大小，最久沒用的先丟;單一聊天太大就不存
/// (並移除舊的，避免顯示過期內容)。資料庫放在這支裝置上，排除備份、檔案保護 `CompleteUntilFirstUserAuthentication`。
/// 任何 SQLite 錯誤都當作快取不可用(讀回 `nil`、寫入忽略):快取只是加速，不能讓聊天打不開。檔案壞掉時刪掉重建。
public actor SQLiteConversationCache: ConversationCache {
    public struct Limits: Sendable, Equatable {
        /// 最多保留的聊天數。
        public var maxChats: Int
        /// 所有聊天加起來的 bytes 上限。
        public var maxTotalBytes: Int
        /// 單一聊天的 bytes 上限(超過就不存)。
        public var maxChatBytes: Int

        public init(maxChats: Int, maxTotalBytes: Int, maxChatBytes: Int) {
            self.maxChats = maxChats
            self.maxTotalBytes = maxTotalBytes
            self.maxChatBytes = maxChatBytes
        }

        /// 正式上限:200 個聊天、總共 32 MiB、單一聊天 4 MiB。
        public static let standard = Limits(maxChats: 200, maxTotalBytes: 32 << 20, maxChatBytes: 4 << 20)
    }

    /// 正式的時鐘(Unix 秒);預設值用常數而不是 closure 字面值(#105 的做法)。
    public static let wallClock: @Sendable () -> Double = { Date().timeIntervalSince1970 }

    private let file: URL
    private let limits: Limits
    private let now: @Sendable () -> Double
    private var handleOwner: Handle?
    private var database: OpaquePointer? { handleOwner?.pointer }
    private var openFailed = false

    /// - Parameters:
    ///   - file: 資料庫檔案(資料夾不存在會建立)。
    ///   - now: 最近使用時間的來源(測試用單調遞增的假時鐘)。
    public init(file: URL, limits: Limits = .standard, now: @escaping @Sendable () -> Double = SQLiteConversationCache.wallClock) {
        self.file = file
        self.limits = limits
        self.now = now
    }

    // MARK: - ConversationCache

    public func load(chatKey: String) -> CachedConversation? {
        guard let database = ensureOpen(), let payload = query(database, "SELECT payload FROM chats WHERE key = ?1", chatKey) else { return nil }
        if let touched = prepare(database, "UPDATE chats SET used = ?2 WHERE key = ?1") {
            bind(touched, text: chatKey, at: 1)
            sqlite3_bind_double(touched, 2, now())
            sqlite3_step(touched)
            sqlite3_finalize(touched)
        }
        return try? JSONDecoder().decode(CachedConversation.self, from: payload)
    }

    public func save(_ conversation: CachedConversation, chatKey: String) {
        guard let database = ensureOpen(), let payload = try? JSONEncoder().encode(conversation) else { return }
        guard payload.count <= limits.maxChatBytes else {
            execute(database, "DELETE FROM chats WHERE key = ?1", chatKey)
            return
        }
        guard let insert = prepare(database, "INSERT OR REPLACE INTO chats (key, payload, size, used) VALUES (?1, ?2, ?3, ?4)") else { return }
        bind(insert, text: chatKey, at: 1)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32(payload.count), Self.transient) }
        sqlite3_bind_int64(insert, 3, Int64(payload.count))
        sqlite3_bind_double(insert, 4, now())
        sqlite3_step(insert)
        sqlite3_finalize(insert)
        enforceLimits(database)
    }

    public func remove(chatKey: String) {
        guard let database = ensureOpen() else { return }
        execute(database, "DELETE FROM chats WHERE key = ?1", chatKey)
    }

    public func removeAll(chatKeyPrefix prefix: String) {
        guard let database = ensureOpen() else { return }
        // `substr` 比對前綴，不用 LIKE:前綴裡的 % 與 _ 不當萬用字元。
        execute(database, "DELETE FROM chats WHERE substr(key, 1, length(?1)) = ?1", prefix)
    }

    // MARK: - 上限

    /// 聊天數與總大小超過上限時，從最久沒用的開始丟。
    private func enforceLimits(_ database: OpaquePointer) {
        guard let rows = prepare(database, "SELECT key, size FROM chats ORDER BY used ASC, key ASC") else { return }
        var entries: [(key: String, size: Int)] = []
        while sqlite3_step(rows) == SQLITE_ROW {
            entries.append((String(cString: sqlite3_column_text(rows, 0)), Int(sqlite3_column_int64(rows, 1))))
        }
        sqlite3_finalize(rows)
        var count = entries.count
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where count > limits.maxChats || total > limits.maxTotalBytes {
            execute(database, "DELETE FROM chats WHERE key = ?1", entry.key)
            count -= 1
            total -= entry.size
        }
    }

    // MARK: - 開啟與 SQLite 小工具

    /// 實例結束時關閉資料庫(actor 的 deinit 不能碰非 Sendable 的指標，所以交給這個擁有者)。
    /// `@unchecked`:`OpaquePointer` 沒標 Sendable;這裡只有一個 `let`,唯一的操作是 deinit 時關閉,不會有並行存取。
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 第一次用到才開。開不起來(或檔案壞掉重建後仍失敗)就一直當作沒有快取。
    private func ensureOpen() -> OpaquePointer? {
        if let database { return database }
        guard !openFailed else { return nil }
        if let opened = open() ?? recreate() {
            handleOwner = Handle(opened)
            return opened
        }
        openFailed = true
        return nil
    }

    private func open() -> OpaquePointer? {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        protect(directory)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        let schema = "CREATE TABLE IF NOT EXISTS chats (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, size INTEGER NOT NULL, used REAL NOT NULL)"
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(handle, "SELECT count(*) FROM chats", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        protect(file)
        return handle
    }

    private func recreate() -> OpaquePointer? {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: file.path + suffix)
        }
        return open()
    }

    /// 排除備份，iOS 上加檔案保護(第一次解鎖後才可讀寫，背景推播啟動也用得到)。
    private func protect(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private func prepare(_ database: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bind(_ statement: OpaquePointer, text: String, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, Self.transient)
    }

    private func execute(_ database: OpaquePointer, _ sql: String, _ text: String) {
        guard let statement = prepare(database, sql) else { return }
        bind(statement, text: text, at: 1)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func query(_ database: OpaquePointer, _ sql: String, _ text: String) -> Data? {
        guard let statement = prepare(database, sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, text: text, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
