import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 對話的 VoiceOver 公告(#35;HIG VoiceOver「Inform VoiceOver when visible content or layout changes occur」):
/// 新的 agent 訊息與狀態變化要公告，但有節流，不在串流時每次更新都念。
@Suite("VoiceOver 公告")
struct ConversationAnnouncerTests {
    static let start = Date(timeIntervalSince1970: 1_000)

    static func user(_ id: String, _ text: String = "hi") -> ConversationItem {
        .user(UserBubble(id: id, text: text, date: nil, imageCount: 0))
    }

    static func agent(_ id: String, _ text: String) -> ConversationItem {
        .agentText(AgentText(id: id, markdown: text, date: nil))
    }

    static func input(_ items: [ConversationItem], _ status: AgentStatus? = .idle, title: String = "ledger") -> ConversationAnnouncer.Input {
        ConversationAnnouncer.Input(items: items, status: status, title: title)
    }

    @Test("第一次載入對話不公告(只是打開畫面)")
    func initialLoadIsSilent() {
        var announcer = ConversationAnnouncer()
        #expect(announcer.observe(Self.input([]), now: Self.start) == nil)
        #expect(announcer.observe(Self.input([Self.user("u1"), Self.agent("a1", "Done.")]), now: Self.start + 1) == nil)
    }

    @Test("新的 agent 訊息：公告 agent 名稱與訊息開頭(markdown 去掉標記)")
    func newAgentMessage() {
        var announcer = ConversationAnnouncer()
        _ = announcer.observe(Self.input([Self.user("u1")], .working), now: Self.start)
        let spoken = announcer.observe(Self.input([Self.user("u1"), Self.agent("a1", "**Fixed** the `export`.")], .working), now: Self.start + 1)
        #expect(spoken == "ledger replied: Fixed the export.")
    }

    @Test("長訊息只念開頭 120 個字")
    func longMessageIsShortened() {
        var announcer = ConversationAnnouncer()
        _ = announcer.observe(Self.input([Self.user("u1")], .working), now: Self.start)
        let long = String(repeating: "word ", count: 60)
        let spoken = announcer.observe(Self.input([Self.user("u1"), Self.agent("a1", long)], .working), now: Self.start + 1)
        #expect(spoken?.hasSuffix("…") == true)
        #expect((spoken?.count ?? 0) <= "ledger replied: ".count + 121)
    }

    @Test("狀態變化：需要你、完成;開始工作不公告(是使用者自己送出的)")
    func statusChanges() {
        var announcer = ConversationAnnouncer()
        let items = [Self.user("u1"), Self.agent("a1", "Hi")]
        _ = announcer.observe(Self.input(items, .idle), now: Self.start)
        #expect(announcer.observe(Self.input(items, .working), now: Self.start + 10) == nil)
        #expect(announcer.observe(Self.input(items, .blocked), now: Self.start + 20) == "ledger needs you")
        _ = announcer.observe(Self.input(items, .working), now: Self.start + 30)
        #expect(announcer.observe(Self.input(items, .done), now: Self.start + 40) == "ledger finished")
    }

    @Test("同一則訊息更新(串流)不重複公告")
    func sameMessageUpdatedIsSilent() {
        var announcer = ConversationAnnouncer()
        _ = announcer.observe(Self.input([Self.user("u1")], .working), now: Self.start)
        _ = announcer.observe(Self.input([Self.user("u1"), Self.agent("a1", "Work")], .working), now: Self.start + 1)
        #expect(announcer.observe(Self.input([Self.user("u1"), Self.agent("a1", "Working on it")], .working), now: Self.start + 20) == nil)
    }

    @Test("節流：上次公告後 4 秒內的變化先留著，到時間只念最新的一則;需要你優先於訊息")
    func throttled() {
        var announcer = ConversationAnnouncer()
        _ = announcer.observe(Self.input([Self.user("u1")], .working), now: Self.start)
        #expect(announcer.observe(Self.input([Self.user("u1"), Self.agent("a1", "One")], .working), now: Self.start + 1) == "ledger replied: One")
        // 1 秒後又一則：先不念。
        let two = [Self.user("u1"), Self.agent("a1", "One"), Self.agent("a2", "Two")]
        #expect(announcer.observe(Self.input(two, .working), now: Self.start + 2) == nil)
        #expect(announcer.pendingDeadline == Self.start + 5)
        // 再一則：取代還沒念的那則。
        let three = two + [Self.agent("a3", "Three")]
        #expect(announcer.observe(Self.input(three, .working), now: Self.start + 3) == nil)
        #expect(announcer.flush(now: Self.start + 4) == nil, "還沒到時間")
        #expect(announcer.flush(now: Self.start + 5) == "ledger replied: Three")
        #expect(announcer.pendingDeadline == nil)
        #expect(announcer.flush(now: Self.start + 6) == nil, "念過就清掉")

        // 需要你與訊息同時排隊：念需要你。
        let four = three + [Self.agent("a4", "Four")]
        _ = announcer.observe(Self.input(four, .blocked), now: Self.start + 6)
        let five = four + [Self.agent("a5", "Five")]
        #expect(announcer.observe(Self.input(five, .blocked), now: Self.start + 7) == nil)
        #expect(announcer.flush(now: Self.start + 10) == "ledger needs you")
    }
}
