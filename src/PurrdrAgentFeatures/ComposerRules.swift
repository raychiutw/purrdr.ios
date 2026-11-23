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

/// 送出鈕的外觀：可送是主色填色；送出中是同樣的主色填色但不可點(不套系統 disabled，
/// 系統 prominent 的停用外觀在深色模式是黑色實心圓);不能送是中性停用樣式(`.fill.tertiary` 底、次要色箭頭)。
public enum ComposerSendAppearance: Sendable, Equatable {
    case prominent
    case sending
    case neutralDisabled

    public init(canSend: Bool, isSending: Bool) {
        self = if isSending { .sending } else if canSend { .prominent } else { .neutralDisabled }
    }

    /// 只有可送時點得到;送出中與不能送都不可點。
    public var isTappable: Bool { self == .prominent }
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

/// 輸入框長高規則(#137,偏離 F6.1 的 4 行):空白時一行高(#196),有內容時至少兩行高(#187),最多 5 行(#382)且不超過
/// 鍵盤上方可用高度的 40%(取小),最小 44pt,超過才在框內捲動。
public enum ComposerSizing {
    public static let maxLines = 5.0
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

// MARK: - 兩態(#382)

/// 輸入列的兩種形態:收合是一列(+、輸入、送出),展開是兩列(上方輸入、下方 +、模型膠囊、送出)。
public enum ComposerForm: Sendable, Equatable {
    case collapsed
    case expanded

    /// 收合只在「沒聚焦、沒有文字、沒有附件」時;其餘展開。
    /// 草稿只有空白或換行也算有內容(使用者打過字，收起鍵盤後草稿還在)。
    public static func resolve(isFocused: Bool, draft: String, hasAttachments: Bool) -> ComposerForm {
        isFocused || !draft.isEmpty || hasAttachments ? .expanded : .collapsed
    }

    /// 模型膠囊只在展開時顯示(收合沒有位置，也不會被截成「Opu…」)。
    public var showsModelCapsule: Bool { self == .expanded }
}

/// 輸入框提示文字的種類(#382):有待回答的「需要你」卡片時提示可以直接告訴 Agent 怎麼做。
public enum ComposerPlaceholderKind: Sendable, Equatable {
    case message
    /// 自訂回答(#120)。
    case typedAnswer
    case tellAgent

    public static func choose(hasTypedAnswer: Bool, hasPendingPrompt: Bool) -> ComposerPlaceholderKind {
        if hasTypedAnswer { return .typedAnswer }
        return hasPendingPrompt ? .tellAgent : .message
    }
}

/// 「+」現在能不能用(#382):離線時附件不能排隊(上傳需要連線)，鈕呈停用外觀但點了會說明;滿 10 個點了提示上限。
public enum ComposerAttachAvailability: Sendable, Equatable {
    case available
    case offline
    case limitReached

    public static func resolve(isOffline: Bool, remainingSlots: Int) -> ComposerAttachAvailability {
        if isOffline { return .offline }
        return remainingSlots > 0 ? .available : .limitReached
    }

    /// 停用外觀(不用系統 disabled:點了要能說明原因)。
    public var isDimmed: Bool { self == .offline }
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

    /// Command-V:剪貼簿只有圖片、沒有文字，且還能加圖片時才當附件;其他一律系統貼上。
    public static func action(hasImages: Bool, hasStrings: Bool, remainingSlots: Int) -> Action {
        hasImages && !hasStrings && remainingSlots > 0 ? .attachImages : .system
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

/// 開頭的 skill／slash 指令(「/名稱」到第一個空白為止):輸入框與聊天裡用系統綠色標出(實機回報 2026-11-20)。
/// 名稱裡有第二個「/」的是路徑(`/Users/demo`),不算。
public enum SlashToken {
    public static func range(in text: String) -> Range<String.Index>? {
        guard text.hasPrefix("/") else { return nil }
        let end = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let name = text[text.index(after: text.startIndex)..<end]
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return text.startIndex..<end
    }

    /// 要上色的所有指令範圍(#469):開頭的 `/名稱` 照 `range(in:)` 一律算;接在空白之後的 `/名稱`(到空白或結尾為止、
    /// 名稱不含 `/`)只有名稱在 `known` 裡才算,所以 `/tmp`、`/usr/bin` 這類路徑與未知字詞不會誤上色。
    public static func ranges(in text: String, known: Set<String>) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        if let leading = range(in: text) { result.append(leading) }
        guard !known.isEmpty else { return result }
        var index = text.startIndex
        var previousIsWhitespace = false
        while index < text.endIndex {
            let character = text[index]
            if character == "/", previousIsWhitespace {
                let end = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                let name = text[text.index(after: index)..<end]
                if !name.isEmpty, !name.contains("/"), known.contains(String(name)) { result.append(index..<end) }
                index = end
                previousIsWhitespace = false
                continue
            }
            previousIsWhitespace = character.isWhitespace
            index = text.index(after: index)
        }
        return result
    }
}
