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

    public init(id: String, text: String, date: Date, state: State = .sending, knownUserIDs: Set<String>, imageCount: Int = 0) {
        self.id = id
        self.text = text
        self.date = date
        self.state = state
        self.knownUserIDs = knownUserIDs
        self.imageCount = imageCount
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
    static func key(_ text: String) -> String {
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

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .echo(let echo): "echo:\(echo.id)"
        }
    }
}

extension ConversationItem {
    /// 項目的時間(沒有時間的種類回傳 `nil`)。
    var date: Date? {
        switch self {
        case .user(let bubble): bubble.date
        case .agentText(let text): text.date
        case .subagent(let card): card.startedAt
        case .workflow(let card): card.startedAt
        case .shell(let run): run.date
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
