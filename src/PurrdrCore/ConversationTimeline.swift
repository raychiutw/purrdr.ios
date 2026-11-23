import Foundation

/// 對話時間軸(GLOSSARY):把對話紀錄的增量維持成有序的列。列身分分配後永不改變;增量只產生新增、原地更新、移除。
public struct ConversationTimeline: Sendable {
    /// 這批變更的原因。
    public enum Cause: Sendable, Equatable {
        /// 新增的列裡有使用者送出的訊息。
        case userSent
        /// 其他新內容(Agent 回覆、工具步驟)。
        case agentReply
        /// 往上補舊訊息。
        case olderLoaded
        /// 整份取代(重新整理、捨棄過舊訊息)。
        case refreshed
    }

    /// 一筆列變更;`at` 是變更後的列位置。
    public enum Change: Sendable, Equatable {
        case inserted(ConversationItem, at: Int)
        case updated(ConversationItem, at: Int)
        case removed(id: String)
    }

    /// 一次輸入造成的變更。
    public struct Update: Sendable, Equatable {
        public var cause: Cause
        public var changes: [Change]

        public init(cause: Cause, changes: [Change]) {
            self.cause = cause
            self.changes = changes
        }
    }

    /// 目前的列,依序。
    public private(set) var items: [ConversationItem] = []

    private var messages: [TranscriptMessage] = []
    private var knownMessageIDs: Set<String> = []
    private var builder = Conversation.Builder()

    public init() {}

    /// 接在最後面的新訊息(已出現過的 id 略過)。
    public mutating func append(_ newMessages: [TranscriptMessage]) -> Update {
        let freshMessages = newMessages.filter { knownMessageIDs.insert($0.id).inserted }
        guard !freshMessages.isEmpty else { return Update(cause: .agentReply, changes: []) }
        messages += freshMessages
        for message in freshMessages where !message.isSidechain {
            builder.add(message)
        }
        let previousItems = items
        items = builder.items
        let changes = Self.changes(from: previousItems, to: items)
        let sentByUser = changes.contains { change in
            if case .inserted(.user(_), _) = change { true } else { false }
        }
        return Update(cause: sentByUser ? .userSent : .agentReply, changes: changes)
    }

    /// 加在最前面的舊訊息(往上補)。最前面的工具串被併入時沿用原本的列身分。
    public mutating func prependOlder(_ olderMessages: [TranscriptMessage]) -> Update {
        let freshMessages = olderMessages.filter { knownMessageIDs.insert($0.id).inserted }
        guard !freshMessages.isEmpty else { return Update(cause: .olderLoaded, changes: []) }
        return rebuild(from: freshMessages + messages, cause: .olderLoaded)
    }

    /// 以新的訊息序列取代全部(重新整理);已存在的列沿用身分。
    public mutating func reset(_ allMessages: [TranscriptMessage]) -> Update {
        var seen = Set<String>()
        return rebuild(from: allMessages.filter { seen.insert($0.id).inserted }, cause: .refreshed)
    }

    /// 捨棄最舊的 `messageCount` 則訊息;留下的列沿用身分。
    public mutating func dropOldest(messageCount: Int) -> Update {
        rebuild(from: Array(messages.dropFirst(max(0, messageCount))), cause: .refreshed)
    }

    // MARK: - 內部

    private mutating func rebuild(from newMessages: [TranscriptMessage], cause: Cause) -> Update {
        let previousItems = items
        messages = newMessages
        knownMessageIDs = Set(newMessages.map(\.id))
        var freshBuilder = Conversation.Builder()
        for message in newMessages where !message.isSidechain {
            freshBuilder.add(message)
        }
        Self.adoptIdentities(of: previousItems, into: &freshBuilder.items)
        builder = freshBuilder
        items = builder.items
        return Update(cause: cause, changes: Self.changes(from: previousItems, to: items))
    }

    /// 新組出的工具串若含有舊列的步驟,沿用舊列的身分。
    private static func adoptIdentities(of previousItems: [ConversationItem], into newItems: inout [ConversationItem]) {
        var rowIDByStepID: [String: String] = [:]
        for case .toolRun(let run) in previousItems {
            for step in run.steps {
                rowIDByStepID[step.id] = run.id
            }
        }
        var adoptedIDs = Set<String>()
        for index in newItems.indices {
            guard case .toolRun(var run) = newItems[index] else { continue }
            guard let existingID = run.steps.lazy.compactMap({ rowIDByStepID[$0.id] }).first,
                  adoptedIDs.insert(existingID).inserted else { continue }
            run.id = existingID
            run.expansionID = existingID
            newItems[index] = .toolRun(run)
        }
    }

    private static func changes(from previousItems: [ConversationItem], to newItems: [ConversationItem]) -> [Change] {
        var previousByID: [String: ConversationItem] = [:]
        for item in previousItems {
            previousByID[item.id] = item
        }
        let newIDs = Set(newItems.map(\.id))
        var changes: [Change] = previousItems.filter { !newIDs.contains($0.id) }.map { .removed(id: $0.id) }
        for (index, item) in newItems.enumerated() {
            if let previous = previousByID[item.id] {
                if previous != item { changes.append(.updated(item, at: index)) }
            } else {
                changes.append(.inserted(item, at: index))
            }
        }
        return changes
    }
}
