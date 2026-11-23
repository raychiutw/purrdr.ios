import Foundation

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
    /// 一般檔案(非圖片)上傳後的路徑:對話紀錄的使用者訊息裡這些路徑行還在文字裡，配對時要算進去。
    public var filePaths: [String]

    public init(
        id: String, text: String, date: Date, state: State = .sending, knownUserIDs: Set<String>, imageCount: Int = 0,
        imageFiles: [String] = [], imagePaths: [String] = [], filePaths: [String] = []
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.state = state
        self.knownUserIDs = knownUserIDs
        self.imageCount = imageCount
        self.imageFiles = imageFiles
        self.imagePaths = imagePaths
        self.filePaths = filePaths
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
        let confirmedIDs = Set(matches(echoes, against: bubbles, consumed: &consumed).map(\.echoID))
        return echoes.filter { !confirmedIDs.contains($0.id) }
    }

    /// 與 `confirm` 同規則,回傳每一組(回音 id、確認它的使用者訊息 id)。
    public static func matches(_ echoes: [PromptEcho], against bubbles: [UserBubble], consumed: inout Set<String>) -> [(echoID: String, bubbleID: String)] {
        var remaining = echoes
        var matched: [(echoID: String, bubbleID: String)] = []
        for bubble in bubbles where !consumed.contains(bubble.id) {
            let bubbleKey = key(bubble.text)
            guard let index = remaining.firstIndex(where: {
                !$0.knownUserIDs.contains(bubble.id) && $0.imageCount == bubble.imageCount && key(UploadedImages.prompt(text: $0.text, paths: $0.filePaths)) == bubbleKey
            }) else { continue }
            consumed.insert(bubble.id)
            matched.append((remaining[index].id, bubble.id))
            remaining.remove(at: index)
        }
        return matched
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

extension ConversationEntry {
    /// 每一輪第一則 Agent 文字的 id(#351):使用者訊息或回音之後的第一則;只有這一則顯示頭像、名稱與時間。
    public static func turnStartTextIDs(in entries: [ConversationEntry]) -> Set<String> {
        var ids: Set<String> = []
        var turnHasText = false
        for entry in entries {
            switch entry {
            case .echo, .item(.user):
                turnHasText = false
            case .item(.agentText(let text)):
                if !turnHasText { ids.insert(text.id) }
                turnHasText = true
            case .item:
                break
            }
        }
        return ids
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
