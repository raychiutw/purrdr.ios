import Foundation
import PurrdrCore

/// 對話畫面的 VoiceOver 公告(#35;HIG VoiceOver:畫面內容改變時告知，`AccessibilityNotification.Announcement`)。
///
/// - 公告：新的 agent 訊息(「<聊天> replied: <開頭>」)、變成需要你、工作結束。開始工作不公告(是使用者自己送出的)。
/// - 打開畫面第一次載入的內容不公告;同一則訊息的更新(串流)不重複公告。
/// - 節流：上次公告後 `minimumInterval` 內的變化先留著，到時間只念最新的一則;「需要你」優先於訊息與完成。
struct ConversationAnnouncer {
    static let minimumInterval: TimeInterval = 4
    /// 訊息只念開頭這麼多字。
    static let previewLength = 120

    struct Input: Equatable {
        var items: [ConversationItem]
        var status: AgentStatus?
        var title: String
    }

    private enum Event {
        case reply(String)
        case needsYou
        case finished

        var priority: Int {
            switch self {
            case .needsYou: 2
            case .reply, .finished: 1
            }
        }
    }

    private var observed = false
    private var hadItems = false
    private var lastAgentMessageID: String?
    private var status: AgentStatus?
    private var lastSpoken: Date?
    private var pending: (event: Event, title: String)?

    /// 留著的公告可以念的時間;沒有留著的公告是 `nil`。
    var pendingDeadline: Date? {
        guard pending != nil else { return nil }
        return lastSpoken.map { $0 + Self.minimumInterval }
    }

    /// 畫面內容更新時呼叫。回傳現在要念的公告。
    mutating func observe(_ input: Input, now: Date) -> String? {
        let message = input.items.last { if case .agentText = $0 { true } else { false } }
        var event: Event?
        if observed {
            if hadItems, let message, case .agentText(let text) = message, message.id != lastAgentMessageID {
                event = .reply(Self.preview(text.markdown))
            }
            if input.status != status {
                switch input.status {
                case .blocked?: event = .needsYou
                case .done?, .idle?:
                    if status == .working, event == nil { event = .finished }
                default: break
                }
            }
        }
        observed = true
        hadItems = !input.items.isEmpty
        lastAgentMessageID = message?.id
        status = input.status
        guard let event else { return nil }

        if let lastSpoken, now < lastSpoken + Self.minimumInterval {
            if let pending, pending.event.priority > event.priority { return nil }
            pending = (event, input.title)
            return nil
        }
        pending = nil
        lastSpoken = now
        return Self.text(event, title: input.title)
    }

    /// 節流時間到了：念留著的公告。
    mutating func flush(now: Date) -> String? {
        guard let pending, let deadline = pendingDeadline, now >= deadline else { return nil }
        self.pending = nil
        lastSpoken = now
        return Self.text(pending.event, title: pending.title)
    }

    private static func text(_ event: Event, title: String) -> String {
        switch event {
        case .reply(let preview): String(localized: "\(title) replied: \(preview)")
        case .needsYou: String(localized: "\(title) needs you")
        case .finished: String(localized: "\(title) finished")
        }
    }

    /// markdown 去掉標記、空白合併成一個，長的截斷加「…」。
    private static func preview(_ markdown: String) -> String {
        let plain = (try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )).map { String($0.characters) } ?? markdown
        let collapsed = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > previewLength else { return collapsed }
        return String(collapsed.prefix(previewLength)) + "…"
    }
}
