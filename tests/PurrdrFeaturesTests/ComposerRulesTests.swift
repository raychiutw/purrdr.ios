import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing

/// 輸入列的純規則：硬體鍵盤的 Return(F6.3)、草稿(F6.2)、回音配對與時間軸(F6.6)。
@MainActor
@Suite("輸入列規則")
struct ComposerRulesTests {
    // MARK: - 硬體鍵盤(F6.3)

    @Test("Command-Return:可送時送出，不可送時什麼都不做")
    func commandReturnSends() {
        #expect(ComposerKeys.actionForReturn(modifiers: .command, returnSends: false, canSend: true, isComposing: false) == .send)
        #expect(ComposerKeys.actionForReturn(modifiers: .command, returnSends: true, canSend: false, isComposing: false) == .ignore)
    }

    @Test("Shift-Return、Option-Return:在游標處換行(不論設定)")
    func shiftAndOptionReturnInsertNewline() {
        for modifiers: ReturnModifiers in [.shift, .option] {
            #expect(ComposerKeys.actionForReturn(modifiers: modifiers, returnSends: true, canSend: true, isComposing: false) == .insertNewline)
        }
    }

    @Test("Return:設定「Return 送出」開時可送就送、不可送什麼都不做(不送空、不插換行);關時換行")
    func plainReturnFollowsSetting() {
        #expect(ComposerKeys.actionForReturn(modifiers: [], returnSends: true, canSend: true, isComposing: false) == .send)
        #expect(ComposerKeys.actionForReturn(modifiers: [], returnSends: true, canSend: false, isComposing: false) == .ignore)
        #expect(ComposerKeys.actionForReturn(modifiers: [], returnSends: false, canSend: true, isComposing: false) == .insertNewline)
    }

    @Test("CJK 輸入法組字中不攔截 Return(交給系統確定選字)")
    func composingIsNeverIntercepted() {
        for modifiers: ReturnModifiers in [[], .command, .shift] {
            #expect(ComposerKeys.actionForReturn(modifiers: modifiers, returnSends: true, canSend: true, isComposing: true) == .system)
        }
    }

    // MARK: - 草稿(F6.2)

    @Test("草稿：離開聊天保留(以 chat key 記);存空字串即刪除")
    func draftsAreKeptPerChat() {
        let drafts = DraftStore()
        drafts.save("還沒寫完", chatKey: "w1:p1", session: "s1")
        #expect(drafts.text(chatKey: "w1:p1", session: "s1") == "還沒寫完")
        #expect(drafts.text(chatKey: "w2:p1", session: "s1") == "")
        drafts.save("", chatKey: "w1:p1", session: "s1")
        #expect(drafts.text(chatKey: "w1:p1", session: nil) == "")
    }

    @Test("草稿：pane 被回收成另一個 session 時顯示空白;任一邊不知道 session 時照常顯示")
    func draftFromRecycledSlotIsHidden() {
        let drafts = DraftStore()
        drafts.save("給舊聊天的話", chatKey: "w1:p1", session: "s1")
        #expect(drafts.text(chatKey: "w1:p1", session: "s2") == "")
        #expect(drafts.text(chatKey: "w1:p1", session: nil) == "給舊聊天的話")
        drafts.save("等 session", chatKey: "w1:p2", session: nil)
        #expect(drafts.text(chatKey: "w1:p2", session: "s9") == "等 session")
    }

    // MARK: - 回音配對(F6.6、R-P08)

    static func bubble(_ id: String, _ text: String, images: Int = 0) -> UserBubble {
        UserBubble(id: id, text: text, date: nil, imageCount: images)
    }

    static func echo(_ id: String, _ text: String, known: Set<String> = []) -> PromptEcho {
        PromptEcho(id: id, text: text, date: Date(timeIntervalSince1970: 0), knownUserIDs: known)
    }

    @Test("回音只能被送出之後才出現的使用者行確認(送出前已存在的同文字訊息不算)")
    func echoIsConfirmedOnlyByNewerLines() {
        var consumed = Set<String>()
        let echoes = [Self.echo("e1", "again", known: ["u1"])]

        let stillOld = EchoMatching.confirm(echoes, against: [Self.bubble("u1", "again")], consumed: &consumed)
        #expect(stillOld.map(\.id) == ["e1"])

        let confirmed = EchoMatching.confirm(echoes, against: [Self.bubble("u1", "again"), Self.bubble("u2", "again")], consumed: &consumed)
        #expect(confirmed.isEmpty)
    }

    @Test("每個到達只能確認一則回音：連送兩次同樣文字，要兩行才全部確認;已用過的行不再確認後來的回音")
    func eachArrivalConfirmsOneEcho() {
        var consumed = Set<String>()
        let echoes = [Self.echo("e1", "ok"), Self.echo("e2", "ok")]

        let afterOne = EchoMatching.confirm(echoes, against: [Self.bubble("u1", "ok")], consumed: &consumed)
        #expect(afterOne.map(\.id) == ["e2"])
        let again = EchoMatching.confirm(afterOne, against: [Self.bubble("u1", "ok")], consumed: &consumed)
        #expect(again.map(\.id) == ["e2"])
        let afterTwo = EchoMatching.confirm(again, against: [Self.bubble("u1", "ok"), Self.bubble("u2", "ok")], consumed: &consumed)
        #expect(afterTwo.isEmpty)
    }

    @Test("配對 key:修剪、連續空行壓成一行;shell 指令正規化成「!」+ 指令;圖片張數要相同")
    func matchingKeyNormalizes() {
        var consumed = Set<String>()
        let echoes = [
            Self.echo("e1", "  第一段\n\n\n第二段  \n"),
            Self.echo("e2", "!ls -la"),
            Self.echo("e3", "看這張"),
        ]
        let remaining = EchoMatching.confirm(echoes, against: [
            Self.bubble("u1", "第一段\n\n第二段"),
            Self.bubble("u2", "! ls -la"),
            Self.bubble("u3", "看這張", images: 1),
        ], consumed: &consumed)
        #expect(remaining.map(\.id) == ["e3"])
    }

    // MARK: - 時間軸

    @Test("未確認的回音依時間併入時間軸;沒有時間的項目沿用上一個已知時間")
    func echoesMergeByTime() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 300)
        let items: [ConversationItem] = [
            .user(UserBubble(id: "u1", text: "a", date: early, imageCount: 0)),
            .note(SystemNote(id: "n1", text: "沒有時間")),
            .agentText(AgentText(id: "a1", markdown: "b", date: late)),
        ]
        let echo = PromptEcho(id: "e1", text: "c", date: Date(timeIntervalSince1970: 200), knownUserIDs: [])

        let entries = EchoTimeline.merge(items: items, echoes: [echo])

        #expect(entries.map(\.id) == ["u1", "n1", "echo:e1", "a1"])
    }
}
