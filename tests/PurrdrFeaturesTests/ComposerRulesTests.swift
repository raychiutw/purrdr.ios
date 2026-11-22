import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Testing

/// 輸入列的純規則：硬體鍵盤的 Return(F6.3)、草稿(F6.2)、回音配對與時間軸(F6.6)。
@MainActor
@Suite("輸入列規則")
struct ComposerRulesTests {
    // MARK: - 送出鈕外觀

    @Test("送出鈕：可送是主色填色、送出中是不可點的主色填色(不套系統停用外觀，深色不變黑色圓);不能送(輸入框空白)是中性停用樣式")
    func sendButtonAppearance() {
        #expect(ComposerSendAppearance(canSend: true, isSending: false) == .prominent)
        #expect(ComposerSendAppearance(canSend: false, isSending: true) == .sending)
        #expect(ComposerSendAppearance(canSend: true, isSending: true) == .sending)
        #expect(ComposerSendAppearance(canSend: false, isSending: false) == .neutralDisabled)
        // 只有 .prominent 可點;送出中與停用都不可點,送出中另以 allowsHitTesting 擋掉,不套系統 disabled
        #expect(ComposerSendAppearance.prominent.isTappable)
        #expect(!ComposerSendAppearance.sending.isTappable)
        #expect(!ComposerSendAppearance.neutralDisabled.isTappable)
    }

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

    // MARK: - 長高(#137)

    /// 行高 20、上下內距 22 時 `lines` 行內容的高度。
    private static func layout(lines: Double, lineHeight: Double = 20, available: Double? = 1000, isEmpty: Bool = false) -> ComposerHeight {
        ComposerSizing.height(
            ComposerTextMetrics(contentHeight: lines * lineHeight + 22, lineHeight: lineHeight, verticalInsets: 22),
            isEmpty: isEmpty, availableHeight: available)
    }

    @Test("長高到 5 行為止(#382),第 6 行才在框內捲動")
    func growsUpToFiveLines() {
        #expect(ComposerSizing.maxLines == 5)
        #expect(Self.layout(lines: 3) == ComposerHeight(height: 82, scrolls: false))
        #expect(Self.layout(lines: 5) == ComposerHeight(height: 122, scrolls: false))
        #expect(Self.layout(lines: 6) == ComposerHeight(height: 122, scrolls: true))
        #expect(Self.layout(lines: 12) == ComposerHeight(height: 122, scrolls: true))
    }

    @Test("可用高度的 40% 比 5 行矮時，以 40% 為上限")
    func availableHeightFractionWins() {
        #expect(Self.layout(lines: 5, available: 300) == ComposerHeight(height: 120, scrolls: true))
        #expect(Self.layout(lines: 4, available: 300) == ComposerHeight(height: 102, scrolls: false))
    }

    @Test("iPhone SE 尺寸加 AX 字級：上限是可用高度的 40%,不是 5 行")
    func smallScreenWithLargeText() {
        // iPhone SE 鍵盤上方約 380pt;AX5 的 body 行高約 64pt。
        #expect(Self.layout(lines: 3, lineHeight: 64, available: 380) == ComposerHeight(height: 152, scrolls: true))
        // 預設字級(行高 22):5 行 132pt 比 152pt 矮，以 5 行為上限;第 6 行起內捲。
        #expect(Self.layout(lines: 8, lineHeight: 22, available: 380) == ComposerHeight(height: 132, scrolls: true))
        #expect(Self.layout(lines: 5, lineHeight: 22, available: 380) == ComposerHeight(height: 132, scrolls: false))
    }

    @Test("空白時一行高(#196 留言),不低於 44pt;大字級時一行也跟著變高")
    func emptyIsOneLine() {
        // 行高 20:一行 42pt,不到 44pt。
        #expect(Self.layout(lines: 1, isEmpty: true) == ComposerHeight(height: 44, scrolls: false))
        // 行高 30:一行 52pt。
        #expect(Self.layout(lines: 1, lineHeight: 30, isEmpty: true) == ComposerHeight(height: 52, scrolls: false))
        // AX5 的 body 行高約 64pt:64 + 22 = 86pt,仍比兩行(150pt)矮。
        #expect(Self.layout(lines: 1, lineHeight: 64, isEmpty: true) == ComposerHeight(height: 86, scrolls: false))
    }

    @Test("有內容時預設高度是兩行(#187):一行內容也留兩行的空間")
    func defaultsToTwoLines() {
        #expect(Self.layout(lines: 1) == ComposerHeight(height: 62, scrolls: false))
        #expect(Self.layout(lines: 2) == ComposerHeight(height: 62, scrolls: false))
        #expect(Self.layout(lines: 3) == ComposerHeight(height: 82, scrolls: false))
        // 行高有小數時無條件進位(2 × 20.3 + 22 = 62.6)。
        #expect(Self.layout(lines: 1, lineHeight: 20.3) == ComposerHeight(height: 63, scrolls: false))
    }

    @Test("兩行的預設高度不超過長高上限;上限再小也不低於 44pt")
    func neverShorterThanMinimum() {
        // 40% 上限 56pt 比兩行(62pt)矮：以上限為準。
        #expect(Self.layout(lines: 1, available: 140) == ComposerHeight(height: 56, scrolls: false))
        #expect(Self.layout(lines: 1, available: 50) == ComposerHeight(height: 44, scrolls: false))
        #expect(Self.layout(lines: 3, available: 50) == ComposerHeight(height: 44, scrolls: true))
        // 行高很小時兩行不到 44pt,仍是 44pt。
        #expect(Self.layout(lines: 1, lineHeight: 8) == ComposerHeight(height: 44, scrolls: false))
    }

    @Test("內容剛好等於上限時不內捲;不知道可用高度時只看 5 行")
    func scrollsOnlyWhenExceeding() {
        let atLimit = ComposerSizing.height(
            ComposerTextMetrics(contentHeight: 120, lineHeight: 20, verticalInsets: 22), isEmpty: false, availableHeight: 300)
        #expect(atLimit == ComposerHeight(height: 120, scrolls: false))
        #expect(Self.layout(lines: 20, available: nil) == ComposerHeight(height: 122, scrolls: true))
    }

    // MARK: - 兩態(#382)

    @Test("收合只有「未聚焦且空白(沒有文字也沒有附件)」;聚焦、有文字或有附件就展開")
    func formCollapsedOnlyWhenIdleAndEmpty() {
        #expect(ComposerForm.resolve(isFocused: false, draft: "", hasAttachments: false) == .collapsed)
        #expect(ComposerForm.resolve(isFocused: true, draft: "", hasAttachments: false) == .expanded)
        #expect(ComposerForm.resolve(isFocused: false, draft: "hi", hasAttachments: false) == .expanded)
        #expect(ComposerForm.resolve(isFocused: false, draft: "", hasAttachments: true) == .expanded)
        // 只有換行也算有內容：使用者打過字，收起鍵盤後草稿還在。
        #expect(ComposerForm.resolve(isFocused: false, draft: "\n", hasAttachments: false) == .expanded)
    }

    @Test("收合是一列:+、輸入、送出;展開才有模型膠囊")
    func formControls() {
        #expect(!ComposerForm.collapsed.showsModelCapsule)
        #expect(ComposerForm.expanded.showsModelCapsule)
    }

    // MARK: - 提示文字(#382)

    @Test("有待回答的「需要你」卡片時，提示改成「或告訴 Agent 怎麼做」;自訂回答優先")
    func placeholderKinds() {
        #expect(ComposerPlaceholderKind.choose(hasTypedAnswer: false, hasPendingPrompt: false) == .message)
        #expect(ComposerPlaceholderKind.choose(hasTypedAnswer: false, hasPendingPrompt: true) == .tellAgent)
        #expect(ComposerPlaceholderKind.choose(hasTypedAnswer: true, hasPendingPrompt: true) == .typedAnswer)
        #expect(ComposerPlaceholderKind.choose(hasTypedAnswer: true, hasPendingPrompt: false) == .typedAnswer)
    }

    // MARK: - 附件可用性(#382)

    @Test("離線時「+」停用(附件不能排隊);滿 10 個點了提示上限;其餘可用")
    func attachAvailability() {
        #expect(ComposerAttachAvailability.resolve(isOffline: true, remainingSlots: 10) == .offline)
        #expect(ComposerAttachAvailability.resolve(isOffline: true, remainingSlots: 0) == .offline)
        #expect(ComposerAttachAvailability.resolve(isOffline: false, remainingSlots: 0) == .limitReached)
        #expect(ComposerAttachAvailability.resolve(isOffline: false, remainingSlots: 3) == .available)
        #expect(ComposerAttachAvailability.offline.isDimmed)
        #expect(!ComposerAttachAvailability.available.isDimmed)
    }

    // MARK: - 組字中的程式覆寫(#138)

    @Test("沒有組字時，程式改寫草稿立即套用")
    func overwriteAppliesWhenNotComposing() {
        var overwrite = ComposerOverwrite()
        #expect(overwrite.request("/compact ", current: "/comp", isComposing: false) == "/compact ")
        #expect(!overwrite.isPending)
    }

    @Test("組字中延後覆寫;組字結束後把接在後面的文字接到確認的字後面(Discuss in Chat)")
    func appendIsDeferredUntilCompositionEnds() {
        var overwrite = ComposerOverwrite()
        #expect(overwrite.request("寫到ㄋ\n\n註記", current: "寫到ㄋ", isComposing: true) == nil)
        #expect(overwrite.isPending)
        #expect(overwrite.inputChanged("寫到ㄋㄧˇ", isComposing: true) == nil)
        #expect(overwrite.inputChanged("寫到你", isComposing: false) == "寫到你\n\n註記")
        #expect(!overwrite.isPending)
        #expect(overwrite.inputChanged("寫到你\n\n註記", isComposing: false) == nil)
    }

    @Test("組字中延後的整段取代(slash 選單填入),組字結束後照樣套用")
    func replacementIsDeferredUntilCompositionEnds() {
        var overwrite = ComposerOverwrite()
        #expect(overwrite.request("/compact ", current: "/ㄋ", isComposing: true) == nil)
        #expect(overwrite.inputChanged("/你", isComposing: false) == "/compact ")
    }

    @Test("組字中多次覆寫：以最後一次為準，接在後面的文字從第一次延後時的內容算起")
    func latestDeferredOverwriteWins() {
        var overwrite = ComposerOverwrite()
        #expect(overwrite.request("寫到ㄋ\n\nA", current: "寫到ㄋ", isComposing: true) == nil)
        #expect(overwrite.inputChanged("寫到ㄋㄧ", isComposing: true) == nil)
        #expect(overwrite.request("寫到ㄋ\n\nA\n\nB", current: "寫到ㄋㄧ", isComposing: true) == nil)
        #expect(overwrite.inputChanged("寫到你", isComposing: false) == "寫到你\n\nA\n\nB")
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

    // MARK: - 圖片(F6.3、F7;#37 故事 33–34)

    @Test("Command-V:剪貼簿只有圖片、沒有文字且還能加時才當附件;否則系統貼上")
    func commandVAttachesImageOnly() {
        #expect(ComposerPaste.action(hasImages: true, hasStrings: false, remainingSlots: 4) == .attachImages)
        #expect(ComposerPaste.action(hasImages: true, hasStrings: true, remainingSlots: 4) == .system)
        #expect(ComposerPaste.action(hasImages: false, hasStrings: true, remainingSlots: 4) == .system)
        #expect(ComposerPaste.action(hasImages: false, hasStrings: false, remainingSlots: 4) == .system)
        // 滿 4 張就交給系統(不吃掉按鍵也不加)。
        #expect(ComposerPaste.action(hasImages: true, hasStrings: false, remainingSlots: 0) == .system)
    }
}
