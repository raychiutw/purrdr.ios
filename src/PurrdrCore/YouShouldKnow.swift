import Foundation

/// 一則「You should know」註記(行為規格 F17):Claude Code 內建 plugin 由旁路 agent 給某個 session 的一句提醒。
public struct YouShouldKnowNote: Equatable, Sendable, Identifiable {
    /// plugin 的 view 種類中，畫面上會顯示成註記的兩種。
    public enum Kind: String, Sendable { case offer, explained }

    /// 註記所屬的 Claude session(完整 id)。
    public var sessionID: String
    public var kind: Kind
    /// 註記的句子。
    public var line: String
    /// offer 的說明(`explanation`)或 explained 的內文(`text`)。
    public var explanation: String?
    /// plugin 給的標籤(例如「Heads up」);沒有時 plugin 顯示 You should know。
    public var tag: String?
    /// 顯示時間(epoch 毫秒);動作只在該列仍是同一則(kind、line、shownAt 相同)時生效。
    public var shownAt: Double?

    public var id: String { sessionID }

    /// 「深入了解」只在 offer 帶有說明時提供(沒有說明時 plugin 要另開 agent 產生，app 做不到)。
    public var canLearnMore: Bool {
        kind == .offer && !(explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var shownDate: Date? { shownAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// 「在聊天中討論」放進輸入框的文字：plugin 自己的草稿格式(引言 + 以 `>` 引用的標籤、句子與說明)。
    ///
    /// 這是**送給 agent 的提示詞**,不是 UI 字串：刻意照 plugin 在 Claude Code 裡產生的英文草稿
    /// (「Here is a note offered by a side agent:」、沒有標籤時的「You should know」),讓 agent 認得出是旁路 agent 的註記，
    /// 不隨裝置語言翻譯(可攜核心也不放顯示字串)。畫面上的標題與按鈕在 Features 在地化。
    public var discussionDraft: String {
        let body = (["\(tag ?? "You should know") · \(line)"] + (explanation.map { [$0] } ?? []))
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "Here is a note offered by a side agent:\n" + body
    }
}

/// 註記的動作(「在聊天中討論」= 把 `discussionDraft` 放進輸入框，再當作「早就知道」)。
public enum YouShouldKnowAction: Sendable, Equatable {
    /// 深入了解：換成「已解釋」view。
    case learnMore
    /// 早就知道：移除 view、句子加入 known、計數器歸零。
    case knewIt
    /// 略過：只移除 view。
    case dismiss
}

public enum YouShouldKnowError: Error, Equatable {
    /// 該列已經不是畫面上那則註記(plugin 換了新的或已處理)。
    case noteChanged
    /// 主機上找不到 store(plugin 沒開，或還沒產生過註記)。
    case storeNotFound
    /// store 不是 JSON 物件，不改它。
    case invalidStore
}

/// plugin 的共用 store(`~/.claude/plugins/store/cc-plugin-you-should-know_<marketplace>-<hash>.json`)。
///
/// 寫回時保留所有未知的鍵、列與欄位：只改動作需要的那幾個值。
public struct YouShouldKnowStore: @unchecked Sendable {
    /// `known` 最多保留的句數(plugin 的上限)。
    static let knownLimit = 50

    private let root: [String: Any]

    public init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.root = root
    }

    private var rows: [[String: Any]] { (root["sessions"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }

    /// 顯示中的註記，新→舊。
    public var notes: [YouShouldKnowNote] {
        rows.compactMap(Self.note(in:)).enumerated()
            .sorted { ($0.element.shownAt ?? 0, -$0.offset) > ($1.element.shownAt ?? 0, -$1.offset) }
            .map(\.element)
    }

    public func note(forSession id: String) -> YouShouldKnowNote? {
        rows.first { $0["id"] as? String == id }.flatMap(Self.note(in:))
    }

    static func note(in row: [String: Any]) -> YouShouldKnowNote? {
        guard let id = row["id"] as? String, let view = row["view"] as? [String: Any],
              let kind = (view["kind"] as? String).flatMap(YouShouldKnowNote.Kind.init(rawValue:)),
              let line = view["line"] as? String, !line.isEmpty
        else { return nil }
        let explanation = (kind == .offer ? view["explanation"] : view["text"]) as? String
        return YouShouldKnowNote(
            sessionID: id, kind: kind, line: line, explanation: explanation, tag: row["tag"] as? String,
            shownAt: (view["shownAt"] as? NSNumber)?.doubleValue)
    }

    /// 套用動作後的新內容。該列已不是 `note` 那則時丟 `YouShouldKnowError.noteChanged`。
    public func applying(_ action: YouShouldKnowAction, to note: YouShouldKnowNote, now: Date) throws -> Data {
        guard var sessions = root["sessions"] as? [Any],
              let index = sessions.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == note.sessionID }),
              var row = sessions[index] as? [String: Any],
              let current = Self.note(in: row), current.kind == note.kind, current.line == note.line, current.shownAt == note.shownAt
        else { throw YouShouldKnowError.noteChanged }
        var root = root
        switch action {
        case .learnMore:
            guard note.canLearnMore, let explanation = note.explanation else { throw YouShouldKnowError.noteChanged }
            row["view"] = [
                "kind": "explained", "line": note.line, "text": explanation, "iteration": 1,
                "shownAt": Int64((now.timeIntervalSince1970 * 1000).rounded()),
            ] as [String: Any]
        case .knewIt:
            row["view"] = nil
            var known = (root["known"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !known.contains(where: { $0.lowercased() == note.line.lowercased() }) { known.append(note.line) }
            root["known"] = Array(known.suffix(Self.knownLimit))
            for counter in ["typedPastInARow", "looksToSkip"] where root[counter] != nil { root[counter] = 0 }
        case .dismiss:
            row["view"] = nil
        }
        sessions[index] = row
        root["sessions"] = sessions
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }
}

/// 「You should know」註記的主機端操作。SSH 實作是 `PurrdrSSH.YouShouldKnowHost`。
public protocol YouShouldKnowHosting: Sendable {
    /// 最新的 store;plugin 沒開過時是 `nil`。
    func locate() async throws -> HostPath?
    /// 讀 store;檔案不見時是 `nil`。
    func read(_ path: HostPath) async throws -> YouShouldKnowStore?
    /// 寫回時用的主機使用者名稱(徵求同意時顯示)。
    func user() async throws -> String
    /// 對註記做動作，寫回 store。
    func perform(_ action: YouShouldKnowAction, on note: YouShouldKnowNote, at path: HostPath) async throws
    /// 撤掉 Purrdr 的修改。
    func restore() async throws
}

/// 「You should know」寫回功能的 id(同意紀錄與安裝紀錄都用它)。
public enum YouShouldKnowFeature {
    public static let id = "you-should-know"
}
