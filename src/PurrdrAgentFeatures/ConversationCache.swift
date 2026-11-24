import Foundation
import PurrdrCore

/// 對話的本地快取(行為規格 F5.2)。離線時顯示、開啟時秒開。
///
/// 每個聊天一筆，戳記是「session + 解析器版本」:session 改變或解析器改版時，舊資料像別的 session 一樣不用。
/// 往上翻的舊頁永不寫入(只存開啟視窗與之後追蹤到的訊息)。清訊息就要清游標，所以兩者存在同一筆。
public protocol ConversationCache: Sendable {
    func load(chatKey: String) async -> CachedConversation?
    func save(_ conversation: CachedConversation, chatKey: String) async
    func remove(chatKey: String) async
    /// 移除 key 以 `prefix` 開頭的所有聊天(刪除主機時清掉那台主機的快取)。
    func removeAll(chatKeyPrefix prefix: String) async
    /// 同步讀取記憶體裡最近開過的聊天(打開聊天時直接有內容,不等非同步讀取);沒有記憶體層的實作回 `nil`。
    func cachedConversation(chatKey: String) -> CachedConversation?
}

extension ConversationCache {
    public func cachedConversation(chatKey: String) -> CachedConversation? { nil }
}

/// 某台主機的對話快取：key 前面加上主機身分，因為 pane id(`w1:p1`)在每台主機都會重複(行為規格 F1.3)。
public struct HostScopedConversationCache: ConversationCache {
    private let base: any ConversationCache
    private let prefix: String

    /// - Parameter scope: 主機身分(主機 id;Demo 主機是 `demo`)。
    public init(base: any ConversationCache, scope: String) {
        self.base = base
        prefix = Self.prefix(scope: scope)
    }

    package static func prefix(scope: String) -> String { scope + "/" }

    public func load(chatKey: String) async -> CachedConversation? { await base.load(chatKey: prefix + chatKey) }
    public func save(_ conversation: CachedConversation, chatKey: String) async { await base.save(conversation, chatKey: prefix + chatKey) }
    public func remove(chatKey: String) async { await base.remove(chatKey: prefix + chatKey) }
    public func removeAll(chatKeyPrefix: String) async { await base.removeAll(chatKeyPrefix: prefix + chatKeyPrefix) }
    public func cachedConversation(chatKey: String) -> CachedConversation? { base.cachedConversation(chatKey: prefix + chatKey) }
}

/// 一個聊天的快取內容。
public struct CachedConversation: Sendable, Equatable, Codable {
    /// 解析器版本：解析規則改了就遞增，讓舊快取失效(否則舊的解析結果永遠不更新)。
    /// 2:加入 subagent／workflow 卡、任務通知與 hand-back(#17;否則快取中的背景 agent 卡永遠「執行中」)。
    /// 3:`!` 指令與輸出解析成 shell 區塊(#43)。
    public static let parserVersion = 3
    /// 每個聊天最多保留的訊息數。
    public static let maxMessages = 500
    /// 尾端一長串工具步驟、可讀訊息在更前面時，快取往前多留到可讀訊息為止的上限(#508)。
    public static let maxMessagesWithReadable = 2_000

    public var sessionID: String
    public var parserVersion: Int
    public var messages: [TranscriptMessage]
    public var metadata: TranscriptMetadata
    /// 對話紀錄在主機上的路徑與已消化的 byte 數。
    public var path: String
    public var cursor: Int
    /// 開啟視窗的 byte 起點(往上翻的錨點)。
    public var windowStart: Int

    public init(sessionID: String, messages: [TranscriptMessage], metadata: TranscriptMetadata, path: String, cursor: Int, windowStart: Int,
                parserVersion: Int = CachedConversation.parserVersion, limit: Int = CachedConversation.maxMessages) {
        self.sessionID = sessionID
        self.parserVersion = parserVersion
        self.messages = Array(messages.suffix(limit))
        self.metadata = metadata
        self.path = path
        self.cursor = cursor
        self.windowStart = windowStart
    }

    /// 屬於 `sessionID` 且是目前解析器產生的。
    public func matches(sessionID: String) -> Bool {
        self.sessionID == sessionID && parserVersion == Self.parserVersion
    }
}

/// 存在記憶體的快取(app 執行期間有效)。
public actor InMemoryConversationCache: ConversationCache {
    private var entries: [String: CachedConversation] = [:]

    public init() {}

    public func load(chatKey: String) -> CachedConversation? { entries[chatKey] }
    public func save(_ conversation: CachedConversation, chatKey: String) { entries[chatKey] = conversation }
    public func remove(chatKey: String) { entries[chatKey] = nil }
    public func removeAll(chatKeyPrefix prefix: String) { entries = entries.filter { !$0.key.hasPrefix(prefix) } }
}
