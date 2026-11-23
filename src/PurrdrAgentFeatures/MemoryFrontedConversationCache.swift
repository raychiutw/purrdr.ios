import Foundation
import PurrdrCore
import Synchronization

/// 在對話快取前面放一層主執行緒也能同步讀的記憶體快取(最近開過的聊天):打開聊天時 model 直接有內容,不閃骨架。
/// 寫入與移除同步更新兩層;`load` 讀過底層後也放進記憶體(Agent 列表預先載入就是呼叫它)。
public final class MemoryFrontedConversationCache: ConversationCache {
    /// 記憶體最多保留的聊天數。
    public static let defaultCapacity = 12

    private struct State {
        var recent: RecentCache<CachedConversation>
        /// 每次寫入或移除遞增;讀取期間有變動就不把讀到的舊值放進記憶體。
        var revision = 0
    }

    private let base: any ConversationCache
    private let state: Mutex<State>

    public init(base: any ConversationCache, capacity: Int = MemoryFrontedConversationCache.defaultCapacity) {
        self.base = base
        state = Mutex(State(recent: RecentCache(capacity: capacity)))
    }

    public func cachedConversation(chatKey: String) -> CachedConversation? {
        state.withLock { $0.recent.value(for: chatKey) }
    }

    public func load(chatKey: String) async -> CachedConversation? {
        let (hit, revisionBefore) = state.withLock { ($0.recent.value(for: chatKey), $0.revision) }
        if let hit { return hit }
        guard let loaded = await base.load(chatKey: chatKey) else { return nil }
        state.withLock { state in
            if state.revision == revisionBefore { state.recent.set(loaded, for: chatKey) }
        }
        return loaded
    }

    public func save(_ conversation: CachedConversation, chatKey: String) async {
        state.withLock { state in
            state.revision &+= 1
            state.recent.set(conversation, for: chatKey)
        }
        await base.save(conversation, chatKey: chatKey)
    }

    public func remove(chatKey: String) async {
        state.withLock { state in
            state.revision &+= 1
            state.recent.remove(chatKey)
        }
        await base.remove(chatKey: chatKey)
    }

    public func removeAll(chatKeyPrefix prefix: String) async {
        state.withLock { state in
            state.revision &+= 1
            state.recent.removeAll(keyPrefix: prefix)
        }
        await base.removeAll(chatKeyPrefix: prefix)
    }
}
