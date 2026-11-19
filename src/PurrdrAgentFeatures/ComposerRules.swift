import Foundation
import PurrdrCore

// MARK: - 硬體鍵盤

/// Return 鍵按下時的修飾鍵。
public struct ReturnModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ReturnModifiers(rawValue: 1 << 0)
    public static let shift = ReturnModifiers(rawValue: 1 << 1)
    public static let option = ReturnModifiers(rawValue: 1 << 2)
}

/// 硬體鍵盤 Return 的處理方式。
public enum ComposerKeyAction: Sendable, Equatable {
    case send
    /// 在游標處換行(取代選取範圍)。
    case insertNewline
    /// 吃掉按鍵，什麼都不做。
    case ignore
    /// 不攔截，交給系統(輸入法組字中)。
    case system
}

/// 硬體鍵盤規則(行為規格 F6.3)。軟體鍵盤的 Return 永遠是換行，不經過這裡。
public enum ComposerKeys {
    /// - Command-Return 永遠送出(可送時)。
    /// - Shift-Return、Option-Return 在游標處換行。
    /// - Return:設定「Return 送出」開(預設)時可送就送、不可送**什麼都不做**(不送空、不插換行);關時換行。
    /// - CJK 輸入法組字中一律不攔截(Return 是確定選字)。
    public static func actionForReturn(modifiers: ReturnModifiers, returnSends: Bool, canSend: Bool, isComposing: Bool) -> ComposerKeyAction {
        if isComposing { return .system }
        if modifiers.contains(.command) { return canSend ? .send : .ignore }
        if !modifiers.isDisjoint(with: [.shift, .option]) || !returnSends { return .insertNewline }
        return canSend ? .send : .ignore
    }
}

/// 送出鈕的外觀：可送或送出中是主色填色，不能送是中性停用樣式(`.fill.tertiary` 底、次要色箭頭)。
public enum ComposerSendAppearance: Sendable, Equatable {
    case prominent
    case neutralDisabled

    public init(canSend: Bool, isSending: Bool) {
        self = canSend || isSending ? .prominent : .neutralDisabled
    }
}

// MARK: - 長高

/// 輸入框的高度與是否在框內捲動。
public struct ComposerHeight: Sendable, Equatable {
    public let height: Double
    public let scrolls: Bool

    public init(height: Double, scrolls: Bool) {
        self.height = height
        self.scrolls = scrolls
    }
}

/// 輸入框內容的量測。
public struct ComposerTextMetrics: Sendable, Equatable {
    /// 內容全部攤開的高度(含上下內距)。
    public var contentHeight: Double
    public var lineHeight: Double
    /// 上下內距合計。
    public var verticalInsets: Double

    public init(contentHeight: Double, lineHeight: Double, verticalInsets: Double) {
        self.contentHeight = contentHeight
        self.lineHeight = lineHeight
        self.verticalInsets = verticalInsets
    }
}

/// 輸入框長高規則(#137,偏離 F6.1 的 4 行):空白時一行高(#196),有內容時至少兩行高(#187),最多 8 行且不超過
/// 鍵盤上方可用高度的 40%(取小),最小 44pt,超過才內捲。
public enum ComposerSizing {
    public static let maxLines = 8.0
    /// 有內容時至少留的行數(上下版面的整寬輸入框，#187)。
    public static let defaultLines = 2.0
    /// 空白時的行數：空白的輸入框佔兩行太高，打字時再長高(#196 留言)。
    public static let emptyLines = 1.0
    public static let availableFraction = 0.4
    public static let minHeight = 44.0

    /// `isEmpty` 是輸入框沒有文字(含組字中的文字);`availableHeight` 是鍵盤上方可用高度，不知道時只看行數。
    public static func height(_ metrics: ComposerTextMetrics, isEmpty: Bool, availableHeight: Double?) -> ComposerHeight {
        let contentHeight = metrics.contentHeight
        var limit = (metrics.lineHeight * maxLines + metrics.verticalInsets).rounded(.up)
        if let availableHeight {
            // 取整點:0.4 不是精確的二進位小數，乘出來可能多一點點。
            limit = min(limit, (availableHeight * availableFraction).rounded())
        }
        limit = max(limit, minHeight)
        let defaultHeight = (metrics.lineHeight * (isEmpty ? emptyLines : defaultLines) + metrics.verticalInsets).rounded(.up)
        let floor = min(max(minHeight, defaultHeight), limit)
        return ComposerHeight(height: max(floor, min(contentHeight, limit)), scrolls: contentHeight > limit)
    }
}

// MARK: - 展開編輯

/// 「展開」鈕(#142):內容超過 2 行或聚焦時顯示，打開展開編輯(large sheet)。
public enum ComposerExpansion {
    public static func showsExpandButton(_ metrics: ComposerTextMetrics, isFocused: Bool) -> Bool {
        if isFocused { return true }
        guard metrics.lineHeight > 0 else { return false }
        // 四捨五入：量到的高度可能比行高的整數倍多一點點。
        return ((metrics.contentHeight - metrics.verticalInsets) / metrics.lineHeight).rounded() > 2
    }
}

// MARK: - 組字

/// 程式對輸入框的整段覆寫(slash 選單填入、Discuss in Chat):組字中延後到組字結束(#138)。
///
/// 延後的內容若是接在當時輸入框文字後面，組字結束時改接在確認的文字後面(不帶入注音符號);否則照樣整段取代。
public struct ComposerOverwrite: Sendable, Equatable {
    /// 第一次延後時輸入框的文字。
    private var base: String?
    /// 最後一次要求的文字。
    private var target: String?

    public init() {}

    /// 是否有延後中的覆寫。
    public var isPending: Bool { target != nil }

    /// 程式要把輸入框改成 `text`(輸入框目前是 `current`)。回傳現在要寫進輸入框的文字;組字中回傳 `nil`(延後)。
    public mutating func request(_ text: String, current: String, isComposing: Bool) -> String? {
        guard isComposing else {
            base = nil
            target = nil
            return text
        }
        if base == nil { base = current }
        target = text
        return nil
    }

    /// 輸入框內容變了。組字剛結束且有延後的覆寫時，回傳要套用的文字。
    public mutating func inputChanged(_ text: String, isComposing: Bool) -> String? {
        guard !isComposing, let base, let target else { return nil }
        self.base = nil
        self.target = nil
        guard target.hasPrefix(base) else { return target }
        return text + target.dropFirst(base.count)
    }
}

// MARK: - 圖片

/// 剪貼簿圖片的規則(行為規格 F6.3、F7;#37 故事 33–34)。只看剪貼簿的**類型**,不讀內容(讀內容會跳「允許貼上」)。
public enum ComposerPaste {
    public enum Action: Sendable, Equatable {
        case attachImages
        case system
    }

    public enum AddImageAction: Sendable, Equatable {
        case openLibrary
        case askSource
        case showLimit
    }

    /// Command-V:剪貼簿只有圖片、沒有文字，且還能加圖片時才當附件;其他一律系統貼上。
    public static func action(hasImages: Bool, hasStrings: Bool, remainingSlots: Int) -> Action {
        hasImages && !hasStrings && remainingSlots > 0 ? .attachImages : .system
    }

    /// 點「加入圖片」:滿了提示;剪貼簿有圖時先問「相簿／貼上圖片」;否則直接開相簿。
    public static func addImageAction(pasteboardHasImages: Bool, remainingSlots: Int) -> AddImageAction {
        if remainingSlots <= 0 { return .showLimit }
        return pasteboardHasImages ? .askSource : .openLibrary
    }
}

// MARK: - 草稿

/// 輸入列草稿(行為規格 F6.2):只在記憶體，key = chat key;離開聊天保留、重開 app 不保留。
///
/// 每份草稿記住打字時的 session;兩邊都知道 session 且不同(pane 被回收成另一個聊天)時顯示空白。
@MainActor
public final class DraftStore {
    private var drafts: [String: (text: String, session: String?)] = [:]

    public init() {}

    public func text(chatKey: String, session: String?) -> String {
        guard let draft = drafts[chatKey] else { return "" }
        if let session, let typed = draft.session, session != typed { return "" }
        return draft.text
    }

    /// 存空字串即刪除。
    public func save(_ text: String, chatKey: String, session: String?) {
        drafts[chatKey] = text.isEmpty ? nil : (text, session)
    }

    private var attachments: [String: [ComposerAttachment]] = [:]

    /// 輸入列上的圖片附件(與草稿一樣離開聊天保留)。
    public func attachments(chatKey: String) -> [ComposerAttachment] {
        attachments[chatKey] ?? []
    }

    public func saveAttachments(_ list: [ComposerAttachment], chatKey: String) {
        attachments[chatKey] = list.isEmpty ? nil : list
    }
}

// MARK: - 回音

/// 送出後立即顯示的本地使用者訊息(樂觀回音，F6.5)。等對話紀錄出現對應的使用者行才消失。
public struct PromptEcho: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case sending
        /// 主機已收下，等對話紀錄確認。
        case sent
        case failed(EchoFailure)
    }

    public var id: String
    public var text: String
    public var date: Date
    public var state: State
    /// 送出當下已存在的使用者訊息 id:這些不能確認這則回音(R-P08)。
    public var knownUserIDs: Set<String>
    public var imageCount: Int
    /// 圖片在手機上的副本檔名(泡泡顯示用)。
    public var imageFiles: [String]
    /// 已上傳到主機的路徑(重試時照樣送，不重傳)。
    public var imagePaths: [String]

    public init(
        id: String, text: String, date: Date, state: State = .sending, knownUserIDs: Set<String>, imageCount: Int = 0,
        imageFiles: [String] = [], imagePaths: [String] = []
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.state = state
        self.knownUserIDs = knownUserIDs
        self.imageCount = imageCount
        self.imageFiles = imageFiles
        self.imagePaths = imagePaths
    }
}

/// 回音失敗的原因(泡泡下方的說明與「重試」)。
public enum EchoFailure: Sendable, Equatable {
    /// 沒有反應(停滯)。
    case noResponse
    /// 無法確認是否送到。
    case unconfirmed(UnconfirmedReason)
}

/// 回音與對話紀錄的配對(F6.6)。
public enum EchoMatching {
    /// 以新到的使用者行確認回音，回傳還沒確認的。`consumed` 記錄已經確認過某則回音的行。
    ///
    /// - 只有**送出之後**才出現的使用者行能確認(比對全部歷史曾讓第二個「again」在送出前就消失)。
    /// - 每個到達只能確認一則回音(最早送出的那則)。
    /// - key = 正規化後的文字 + 圖片張數。
    public static func confirm(_ echoes: [PromptEcho], against bubbles: [UserBubble], consumed: inout Set<String>) -> [PromptEcho] {
        var remaining = echoes
        for bubble in bubbles where !consumed.contains(bubble.id) {
            let bubbleKey = key(bubble.text)
            guard let index = remaining.firstIndex(where: {
                !$0.knownUserIDs.contains(bubble.id) && $0.imageCount == bubble.imageCount && key($0.text) == bubbleKey
            }) else { continue }
            consumed.insert(bubble.id)
            remaining.remove(at: index)
        }
        return remaining
    }

    /// 修剪、行尾空白去掉、連續空行壓成一行;shell 指令(`!` 開頭)正規化成 `!` + 修剪後的指令。
    package static func key(_ text: String) -> String {
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.reversed().drop { $0.isWhitespace }.reversed()
            let line = Substring(String(trimmed))
            if line.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.hasPrefix("!") else { return joined }
        return "!" + joined.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 對話畫面的一列：對話紀錄的項目，或還沒確認的回音。
public enum ConversationEntry: Sendable, Equatable, Identifiable {
    case item(ConversationItem)
    case echo(PromptEcho)

    /// 回音列的 id 前綴(捲動調整以它分辨回音，#130)。
    public static let echoIDPrefix = "echo:"

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .echo(let echo): Self.echoIDPrefix + echo.id
        }
    }
}

extension ConversationItem {
    /// 項目的時間(沒有時間的種類回傳 `nil`)。
    package var date: Date? {
        switch self {
        case .user(let bubble): bubble.date
        case .agentText(let text): text.date
        case .subagent(let card): card.startedAt
        case .workflow(let card): card.startedAt
        case .shell(let run): run.date
        case .agentFile(let card): card.date
        case .toolRun, .skill, .note: nil
        }
    }
}

public enum EchoTimeline {
    /// 未確認的回音依時間併入;沒有時間的項目沿用上一個已知時間(F6.6)。
    public static func merge(items: [ConversationItem], echoes: [PromptEcho]) -> [ConversationEntry] {
        var pending = echoes.sorted { $0.date < $1.date }[...]
        var entries: [ConversationEntry] = []
        var lastDate = Date.distantPast
        for item in items {
            lastDate = item.date ?? lastDate
            while let echo = pending.first, echo.date < lastDate {
                entries.append(.echo(echo))
                pending.removeFirst()
            }
            entries.append(.item(item))
        }
        entries += pending.map(ConversationEntry.echo)
        return entries
    }
}

// MARK: - 鍵盤出現時的版面

/// 輸入框上方可讓位的元素(You should know 註記、建議提示詞)的顯示方式(#196)。
public enum ComposerAccessoryForm: Sendable, Equatable {
    /// 完整卡片。
    case full
    /// 收成一行(44pt)。
    case compact
    case hidden
}

/// 註記、建議提示詞與停止列各自的顯示方式。
public struct ComposerAccessoryArrangement: Sendable, Equatable {
    public var note: ComposerAccessoryForm
    public var suggestion: ComposerAccessoryForm
    /// 停止列(#220):只會 `.full` 或 `.compact`(只留停止鈕)。
    public var stopBar: ComposerAccessoryForm

    public init(note: ComposerAccessoryForm, suggestion: ComposerAccessoryForm, stopBar: ComposerAccessoryForm = .full) {
        self.note = note
        self.suggestion = suggestion
        self.stopBar = stopBar
    }

    public static let full = ComposerAccessoryArrangement(note: .full, suggestion: .full)

    /// 輸入框上方一次只顯示一樣完整卡片：You should know 完整顯示時建議卡收起，註記收成一行或拿掉後建議卡才出現。
    public func sharingTopSlot(hasNote: Bool) -> ComposerAccessoryArrangement {
        guard hasNote, note == .full else { return self }
        return ComposerAccessoryArrangement(note: note, suggestion: .hidden, stopBar: stopBar)
    }

    /// 暫時拿掉的元素換回一行，其他維持。
    var restoringHidden: ComposerAccessoryArrangement {
        ComposerAccessoryArrangement(
            note: note == .hidden ? .compact : note, suggestion: suggestion == .hidden ? .compact : suggestion, stopBar: .full)
    }
}

/// 一個可讓位元素各種顯示方式的高度(不含與下一個元素的間距)。
public struct ComposerAccessoryHeights: Sendable, Equatable {
    /// 完整卡片的高度;還沒以完整卡片排過時是 `nil`(不知道放不放得下，當作放不下)。
    public var full: Double?
    /// 收成一行的高度(沒量過時用 44pt 估)。
    public var compact: Double

    public init(full: Double?, compact: Double = ComposerKeyboardLayout.compactHeight) {
        self.full = full
        self.compact = compact
    }
}

/// 鍵盤出現時輸入列上方元素的讓位規則(#196,DESIGN.md「輸入列」)。
public enum ComposerKeyboardLayout {
    /// 輸入列 VStack 裡元素之間的間距(`ComposerBar` 直接用它排版)。
    public static let spacing = 8.0
    /// 收成一行的高度，也是一列觸控目標的高度(一行的註記與建議提示詞直接用它當最小高度)。
    public static let compactHeight = 44.0

    /// 對話至少保留的可見高度。
    ///
    /// 3 列觸控高度(132pt)與 3 行內文加列表上下內距(大字級時較高)取大，讓打字時看得到最新的一兩則訊息
    /// (HIG Virtual keyboards:鍵盤出現時輸入列與最新訊息不被遮)。
    public static func minimumConversationHeight(bodyLineHeight: Double) -> Double {
        max(3 * compactHeight, (3 * bodyLineHeight + 24).rounded(.up))
    }

    /// 依目前的對話可見高度與目前的顯示方式，決定註記與建議提示詞的顯示方式。
    public static func arrangement(
        keyboardShown: Bool, conversationHeight: Double?, current: ComposerAccessoryArrangement,
        note: ComposerAccessoryHeights?, suggestion: ComposerAccessoryHeights?, stopBar: ComposerAccessoryHeights? = nil,
        minimumConversationHeight: Double
    ) -> ComposerAccessoryArrangement {
        // 鍵盤收起時不長回完整卡片：卡片若跟著鍵盤收起一起長回來，先以沒量過的高度排一次、量到後再排一次，
        // 輸入列高度在鍵盤動畫中連跳兩次，又碰上大量輸出重建列表(#130)時對話會停在一片空白。點一行的註記才展開
        // (`ComposerBar`)。暫時拿掉的元素則回到一行：拿掉只是鍵盤在時的讓位，鍵盤收起後要叫得回來;一行的高度固定
        // (不必重新量)，只在失焦當下變一次，不會在動畫中連跳。
        guard keyboardShown else { return current.restoringHidden }
        guard let conversationHeight else { return current }
        // 可分配的高度與目前怎麼排無關：對話可見高度加上目前顯示中的元素(含間距)。
        let budget = conversationHeight + displayedCost(note, current.note) + displayedCost(suggestion, current.suggestion)
            + displayedCost(stopBar, current.stopBar)
        // 依優先順序讓位：輸入框最優先(不讓)、停止列次之(唯一的停止入口，只收成一行，#220)、
        // 建議提示詞再次之(Tab 可接受，跟打字有關)、註記最後。
        let candidates: [ComposerAccessoryArrangement] = [
            .full,
            ComposerAccessoryArrangement(note: .compact, suggestion: .full),
            ComposerAccessoryArrangement(note: .compact, suggestion: .compact),
            ComposerAccessoryArrangement(note: .hidden, suggestion: .compact),
            ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden),
            ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden, stopBar: .compact),
        ]
        let chosen = candidates.first { candidate in
            budget - cost(note, candidate.note) - cost(suggestion, candidate.suggestion) - cost(stopBar, candidate.stopBar)
                >= minimumConversationHeight
        } ?? candidates[candidates.count - 1]
        // 暫時不在的元素(送出後重讀註記、換建議)維持目前的顯示方式：回來時不先以完整卡片出現再收起，
        // 輸入列高度一下子跳很多會讓對話列表停在內容之外。
        return ComposerAccessoryArrangement(
            note: note == nil ? current.note : chosen.note,
            suggestion: suggestion == nil ? current.suggestion : chosen.suggestion,
            stopBar: stopBar == nil ? current.stopBar : chosen.stopBar)
    }

    /// 目前顯示中的元素佔的高度(含間距)。完整卡片剛出現、還沒量到時先以一行估。
    private static func displayedCost(_ heights: ComposerAccessoryHeights?, _ form: ComposerAccessoryForm) -> Double {
        guard let heights, form == .full, heights.full == nil else { return cost(heights, form) }
        return heights.compact + spacing
    }

    /// 元素以 `form` 顯示時佔的高度(含間距)。沒量過的完整卡片當作放不下。
    private static func cost(_ heights: ComposerAccessoryHeights?, _ form: ComposerAccessoryForm) -> Double {
        guard let heights else { return 0 }
        switch form {
        case .full: return (heights.full ?? .infinity) + spacing
        case .compact: return heights.compact + spacing
        case .hidden: return 0
        }
    }
}
