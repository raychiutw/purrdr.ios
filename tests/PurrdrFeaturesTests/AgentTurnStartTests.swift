import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// Agent 回覆不包泡泡，每一輪開頭才有頭像、名稱與時間(#351)。
@Suite("Agent 回覆的輪次開頭")
struct AgentTurnStartTests {
    private func user(_ id: String) -> ConversationEntry {
        .item(.user(UserBubble(id: id, text: "hi", date: nil, imageCount: 0)))
    }

    private func agent(_ id: String) -> ConversationEntry {
        .item(.agentText(AgentText(id: id, markdown: "ok", date: nil)))
    }

    private func note(_ id: String) -> ConversationEntry {
        .item(.note(SystemNote(id: id, text: "note")))
    }

    @Test("使用者訊息之後的第一則 Agent 文字是輪次開頭，同一輪後面的不是")
    func firstTextAfterUserStartsTheTurn() {
        let entries = [user("u1"), note("s1"), agent("a1"), agent("a2"), user("u2"), agent("a3")]
        #expect(ConversationEntry.turnStartTextIDs(in: entries) == ["a1", "a3"])
    }

    @Test("對話一開始就是 Agent 文字時，它是輪次開頭")
    func leadingAgentTextStartsTheTurn() {
        #expect(ConversationEntry.turnStartTextIDs(in: [agent("a1"), agent("a2")]) == ["a1"])
    }
}
