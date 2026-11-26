import Foundation

/// 對話時間軸(GLOSSARY):把對話紀錄與回音的增量維持成有序的列。列身分分配後永不改變;增量只產生新增、原地更新、往上補、移除。
/// 列的展開狀態與 Markdown 解析結果也存在這一側,不放在畫面元件裡。
public struct ConversationTimeline: Sendable {
    /// 這批變更的原因。
    public enum Cause: Sendable, Equatable {
        /// 使用者送出(新的使用者訊息、回音,或回音被確認)。
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
        /// 新增(新內容、送出的回音)。
        case inserted(ConversationRow, at: Int)
        /// 原地更新(工具串多一步、回音確認或改狀態)。
        case updated(ConversationRow, at: Int)
        /// 往上補舊訊息時新出現的列。
        case prepended(ConversationRow, at: Int)
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

    /// 目前的項目(只含對話紀錄的項目,依序)。
    public var items: [ConversationItem] { builder.items.values }
    /// 目前的列(對話紀錄的項目加上還沒確認的回音),依序。列的 `id` 分配後不變。
    public private(set) var rows: [ConversationRow] = []
    /// 還沒被對話紀錄確認的回音。
    public private(set) var pendingEchoes: [PromptEcho] = []
    /// Markdown 實際解析的次數(測試用:同一段文字只解析一次)。
    package private(set) var markdownParseCount = 0
    /// 送進建構器的訊息總數(測試用:往上翻只建構新頁、補讀完只重建一次,#586)。
    package private(set) var builtMessageCount = 0

    /// 重算過的列數總計(測試用:附加新訊息只重算被改動的那一段,#586)。
    package private(set) var recomputedRowCount = 0

    /// 畫面列的建構輸入(不是讀取與快取的真相:那在 `ConversationModel` 的 `recent`／`olderMessages`;這裡依 id 去重自保)。
    private var messages: [TranscriptMessage] = []
    private var knownMessageIDs: Set<String> = []
    private var builder = Conversation.Builder()
    private var consumedUserIDs: Set<String> = []
    /// 確認了回音的使用者項目 id → 沿用的回音列 id。
    private var rowIDByConfirmedItemID: [String: String] = [:]
    private var expandedRowIDs: Set<String> = []
    /// 列 id → 展開的子項 id(思考、呼叫結果等列內的可展開區塊)。
    private var expandedPartIDsByRowID: [String: Set<String>] = [:]
    private var markdownCache: [String: (source: String, blocks: [MarkdownBlock])] = [:]

    public init() {}

    // MARK: - 輸入

    /// 接在最後面的新訊息(已出現過的 id 略過)。新到的使用者訊息會確認還沒確認的回音(原地更新那一列)。
    public mutating func append(_ newMessages: [TranscriptMessage]) -> Update {
        let freshMessages = newMessages.filter { knownMessageIDs.insert($0.id).inserted }
        guard !freshMessages.isEmpty else { return Update(cause: .agentReply, changes: []) }
        messages += freshMessages
        builder.items.resetTouched()
        let previousCount = builder.items.count
        for message in freshMessages where !message.isSidechain {
            builder.add(message)
        }
        builtMessageCount += freshMessages.count
        // 沒有回音要合併時,列就是項目逐一換成列:只重算被改動的那一段,不走訪全部(#586)。
        if pendingEchoes.isEmpty, rows.count == previousCount {
            return refreshTail(from: min(builder.items.lowestTouched, previousCount))
        }
        return refreshRows(cause: nil, prepending: false)
    }

    /// 加在最前面的舊訊息(往上補)。最前面的工具串被併入時沿用原本的列身分;新出現的列是 `.prepended`。
    public mutating func prependOlder(_ olderMessages: [TranscriptMessage]) -> Update {
        let freshMessages = olderMessages.filter { knownMessageIDs.insert($0.id).inserted }
        guard !freshMessages.isEmpty else { return Update(cause: .olderLoaded, changes: []) }
        // 只建構新的一頁再接到最前面;有只能整份重建才對得上的相依時才整份重建(#586)。
        builtMessageCount += freshMessages.count
        if builder.prepend(Self.build(freshMessages)) {
            messages = freshMessages + messages
            return refreshRows(cause: .olderLoaded, prepending: true)
        }
        return rebuild(from: freshMessages + messages, cause: .olderLoaded, prepending: true)
    }

    /// 以新的訊息序列取代全部(重新整理);已存在的列沿用身分。
    public mutating func reset(_ allMessages: [TranscriptMessage]) -> Update {
        var seen = Set<String>()
        return rebuild(from: allMessages.filter { seen.insert($0.id).inserted }, cause: .refreshed, prepending: false)
    }

    /// 捨棄最舊的 `messageCount` 則訊息;留下的列沿用身分。
    public mutating func dropOldest(messageCount: Int) -> Update {
        rebuild(from: Array(messages.dropFirst(max(0, messageCount))), cause: .refreshed, prepending: false)
    }

    /// 以回音的目前清單同步(新送出、改狀態、移除);已有對話紀錄確認的回音會被確認並從 `pendingEchoes` 拿掉。
    public mutating func setEchoes(_ echoes: [PromptEcho]) -> Update {
        pendingEchoes = echoes
        return refreshRows(cause: .userSent, prepending: false)
    }

    // MARK: - 列的狀態(跟著列,不放在畫面元件裡)

    /// 列(或列內的子項)是否展開。`partID` 為 `nil` 是整列(工具串),否則是列內以穩定 id 區分的子項(思考、呼叫結果)。預設收起。
    public func isExpanded(rowID: String, partID: String? = nil) -> Bool {
        guard let partID else { return expandedRowIDs.contains(rowID) }
        return expandedPartIDsByRowID[rowID]?.contains(partID) ?? false
    }

    /// 設定展開狀態;跨增量保留,列被移除時連同子項一起清掉。
    public mutating func setExpanded(_ expanded: Bool, rowID: String, partID: String? = nil) {
        guard let partID else {
            if expanded {
                expandedRowIDs.insert(rowID)
            } else {
                expandedRowIDs.remove(rowID)
            }
            return
        }
        if expanded {
            expandedPartIDsByRowID[rowID, default: []].insert(partID)
        } else {
            expandedPartIDsByRowID[rowID]?.remove(partID)
            if expandedPartIDsByRowID[rowID]?.isEmpty == true {
                expandedPartIDsByRowID[rowID] = nil
            }
        }
    }

    /// Agent 文字的 Markdown 解析結果;同一則、文字沒變時重用,不再解析。
    public mutating func markdownBlocks(for text: AgentText) -> [MarkdownBlock] {
        if let cached = markdownCache[text.id], cached.source == text.markdown {
            return cached.blocks
        }
        let blocks = Markdown.parse(text.markdown)
        markdownParseCount += 1
        markdownCache[text.id] = (text.markdown, blocks)
        return blocks
    }

    // MARK: - 內部

    private mutating func rebuild(from newMessages: [TranscriptMessage], cause: Cause, prepending: Bool) -> Update {
        messages = newMessages
        knownMessageIDs = Set(newMessages.map(\.id))
        builtMessageCount += newMessages.count
        var freshBuilder = Self.build(newMessages)
        var adopted = freshBuilder.items.values
        Self.adoptIdentities(of: items, into: &adopted)
        freshBuilder.items = Conversation.TrackedItems(adopted)
        builder = freshBuilder
        return refreshRows(cause: cause, prepending: prepending)
    }

    private static func build(_ messages: [TranscriptMessage]) -> Conversation.Builder {
        var builder = Conversation.Builder()
        builder.defersSummaries = true
        for message in messages where !message.isSidechain {
            builder.add(message)
        }
        builder.settleSummaries()
        return builder
    }

    /// 附加新訊息後的增量更新(沒有回音待合併):只重算 `start` 之後的列與差異,其餘列原封不動。
    private mutating func refreshTail(from start: Int) -> Update {
        let all = builder.items.values
        let previousTail = Array(rows[start...])
        let newTail: [ConversationRow] = all[start...].map { item in
            ConversationRow(id: rowIDByConfirmedItemID[item.id] ?? item.id, entry: .item(item))
        }
        rows.replaceSubrange(start..., with: newTail)
        recomputedRowCount += newTail.count
        let changes = Self.changes(from: previousTail, to: newTail, prepending: false, offset: start)
        // 有列被移除才需要清狀態;單純附加或原地更新不必走訪全部。
        if changes.contains(where: { if case .removed = $0 { true } else { false } }) { pruneState() }
        let sentByUser = changes.contains { change in
            if case .inserted(let row, _) = change, row.isUserSent { true } else { false }
        }
        return Update(cause: sentByUser ? .userSent : .agentReply, changes: changes)
    }

    /// 依目前的項目與回音確認回音、重算列,回傳與上一版列的差異。`cause` 為 `nil` 時依內容推斷。
    private mutating func refreshRows(cause: Cause?, prepending: Bool) -> Update {
        let confirmedNow = confirmEchoes()
        let previousRows = rows
        defer { recomputedRowCount += rows.count }
        rows = EchoTimeline.merge(items: items, echoes: pendingEchoes).map { entry in
            switch entry {
            case .item(let item): ConversationRow(id: rowIDByConfirmedItemID[item.id] ?? item.id, entry: entry)
            case .echo(let echo): ConversationRow(id: ConversationEntry.echoIDPrefix + echo.id, entry: entry)
            }
        }
        let changes = Self.changes(from: previousRows, to: rows, prepending: prepending)
        pruneState()
        let resolvedCause: Cause
        if let cause {
            resolvedCause = cause
        } else {
            let sentByUser = confirmedNow || changes.contains { change in
                if case .inserted(let row, _) = change, row.isUserSent { true } else { false }
            }
            resolvedCause = sentByUser ? .userSent : .agentReply
        }
        return Update(cause: resolvedCause, changes: changes)
    }

    /// 以對話紀錄的使用者訊息確認回音;回傳這次有沒有確認任何一則。
    private mutating func confirmEchoes() -> Bool {
        guard !pendingEchoes.isEmpty else { return false }
        let matches = EchoMatching.matches(pendingEchoes, against: Self.userTurns(in: items), consumed: &consumedUserIDs)
        guard !matches.isEmpty else { return false }
        let confirmedEchoIDs = Set(matches.map(\.echoID))
        for match in matches {
            rowIDByConfirmedItemID[match.bubbleID] = ConversationEntry.echoIDPrefix + match.echoID
        }
        pendingEchoes.removeAll { confirmedEchoIDs.contains($0.id) }
        return true
    }

    /// 使用者送出的內容:泡泡,以及 shell 區塊(以 `!指令` 比對回音)。
    private static func userTurns(in items: [ConversationItem]) -> [UserBubble] {
        items.compactMap { item -> UserBubble? in
            switch item {
            case .user(let bubble): bubble
            case .shell(let run): UserBubble(id: run.id, text: "!" + run.command, date: run.date, imageCount: 0)
            default: nil
            }
        }
    }

    /// 列被移除後,清掉它的展開狀態、Markdown 結果與回音對應。
    private mutating func pruneState() {
        let liveRowIDs = Set(rows.map(\.id))
        expandedRowIDs.formIntersection(liveRowIDs)
        expandedPartIDsByRowID = expandedPartIDsByRowID.filter { liveRowIDs.contains($0.key) }
        let liveItemIDs = Set(items.map(\.id))
        markdownCache = markdownCache.filter { liveItemIDs.contains($0.key) }
        rowIDByConfirmedItemID = rowIDByConfirmedItemID.filter { liveItemIDs.contains($0.key) }
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

    private static func changes(from previousRows: [ConversationRow], to newRows: [ConversationRow], prepending: Bool, offset: Int = 0) -> [Change] {
        var previousByID: [String: ConversationRow] = [:]
        for row in previousRows {
            previousByID[row.id] = row
        }
        let newIDs = Set(newRows.map(\.id))
        var changes: [Change] = previousRows.filter { !newIDs.contains($0.id) }.map { .removed(id: $0.id) }
        for (index, row) in newRows.enumerated() {
            if let previous = previousByID[row.id] {
                if previous != row { changes.append(.updated(row, at: index + offset)) }
            } else {
                changes.append(prepending ? .prepended(row, at: index + offset) : .inserted(row, at: index + offset))
            }
        }
        return changes
    }
}

/// 對話時間軸的一列:`id` 分配後不變(回音確認後仍沿用回音的 id),`entry` 是目前的內容。
public struct ConversationRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var entry: ConversationEntry

    public init(id: String, entry: ConversationEntry) {
        self.id = id
        self.entry = entry
    }

    /// 對話紀錄的項目(回音沒有)。
    public var item: ConversationItem? {
        if case .item(let item) = entry { item } else { nil }
    }

    fileprivate var isUserSent: Bool {
        switch entry {
        case .echo, .item(.user): true
        default: false
        }
    }
}
