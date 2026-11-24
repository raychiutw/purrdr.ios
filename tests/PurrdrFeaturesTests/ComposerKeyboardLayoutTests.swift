import PurrdrAgentFeatures
import Testing

/// 鍵盤出現時輸入列上方元素的讓位規則(#196)。
///
/// 數字取自 #191 在 iPhone 17 以軟體注音鍵盤重現的版面：You should know 卡片約 285pt、兩行的建議提示詞約 60pt,
/// 卡片、建議列、輸入列與鍵盤同時在時對話只剩 6pt。
@Suite("鍵盤出現時的版面")
struct ComposerKeyboardLayoutTests {
    private static let note = ComposerAccessoryHeights(full: 285, compact: 44)
    private static let suggestion = ComposerAccessoryHeights(full: 60, compact: 44)
    private static let minimum = 132.0

    /// 停止列有結果時兩行(約 72pt),只留停止鈕時一行(#220)。
    private static let stopBar = ComposerAccessoryHeights(full: 72, compact: 44)

    private static func arrange(
        keyboard: Bool = true, conversation: Double?, current: ComposerAccessoryArrangement = .full,
        note: ComposerAccessoryHeights? = Self.note, suggestion: ComposerAccessoryHeights? = Self.suggestion,
        stopBar: ComposerAccessoryHeights? = nil
    ) -> ComposerAccessoryArrangement {
        ComposerKeyboardLayout.arrangement(
            keyboardShown: keyboard, conversationHeight: conversation, current: current,
            note: note, suggestion: suggestion, stopBar: stopBar, minimumConversationHeight: minimum)
    }

    @Test("停止列排在輸入列之後、建議提示詞之前：註記與建議都拿掉仍放不下，才收成只有停止鈕的一行，永不拿掉")
    func stopBarYieldsLastAndNeverHides() {
        // 全部完整時的可分配高度 = 對話 + 293 + 68 + 80。
        let allShed = 132 - 361 - 80 + 80
        #expect(Self.arrange(conversation: Double(allShed), stopBar: Self.stopBar)
            == ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden, stopBar: .full))
        #expect(Self.arrange(conversation: Double(allShed - 1), stopBar: Self.stopBar)
            == ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden, stopBar: .compact))
        #expect(Self.arrange(conversation: -800, stopBar: Self.stopBar)
            == ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden, stopBar: .compact))
    }

    @Test("停止列收成一行後空間回來就恢復;鍵盤收起時也恢復")
    func stopBarRestores() {
        let shed = ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden, stopBar: .compact)
        #expect(Self.arrange(conversation: 900, current: shed, stopBar: Self.stopBar) == .full)
        #expect(Self.arrange(keyboard: false, conversation: nil, current: shed, stopBar: Self.stopBar).stopBar == .full)
    }

    @Test("最小對話可見高度：預設字級 132pt(3 列 44pt);大字級時是 3 行內文加列表上下內距")
    func minimumConversationHeight() {
        #expect(ComposerKeyboardLayout.minimumConversationHeight(bodyLineHeight: 22) == 132)
        // AX5 的 body 行高約 64pt:3 × 64 + 24。
        #expect(ComposerKeyboardLayout.minimumConversationHeight(bodyLineHeight: 64) == 216)
    }

    @Test("鍵盤收起時維持目前的顯示方式(點一行的註記才展開):不與鍵盤收起同時讓輸入列一下子長高")
    func keyboardHiddenKeepsArrangement() {
        let current = ComposerAccessoryArrangement(note: .compact, suggestion: .compact)
        #expect(Self.arrange(keyboard: false, conversation: 600, current: current) == current)
        #expect(Self.arrange(keyboard: false, conversation: 6) == .full)
    }

    @Test("鍵盤收起時暫時拿掉的註記與建議提示詞回到一行(可點)，不直接長回完整卡片")
    func keyboardHiddenRestoresHiddenAsCompact() {
        let shed = ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden)
        #expect(Self.arrange(keyboard: false, conversation: 600, current: shed) == ComposerAccessoryArrangement(note: .compact, suggestion: .compact))
        let partly = ComposerAccessoryArrangement(note: .hidden, suggestion: .full)
        #expect(Self.arrange(keyboard: false, conversation: nil, current: partly) == ComposerAccessoryArrangement(note: .compact, suggestion: .full))
        // 元素暫時不在時也一樣：回來時是可點的一行。
        #expect(Self.arrange(keyboard: false, conversation: nil, current: shed, note: nil, suggestion: nil)
            == ComposerAccessoryArrangement(note: .compact, suggestion: .compact))
    }

    @Test("iPhone 17 軟體鍵盤：註記先收成一行，建議提示詞照常，對話留 247pt")
    func iPhoneSoftKeyboardCollapsesNoteFirst() {
        // 對話 6pt + 卡片 285 + 8 + 建議 60 + 8 = 367pt 可分配;註記收成一行後對話 367 − 52 − 68 = 247。
        #expect(Self.arrange(conversation: 6) == ComposerAccessoryArrangement(note: .compact, suggestion: .full))
    }

    @Test("讓位後重新量到的高度不會讓版面來回切換")
    func arrangementIsStable() {
        let collapsed = ComposerAccessoryArrangement(note: .compact, suggestion: .full)
        #expect(Self.arrange(conversation: 247, current: collapsed) == collapsed)
    }

    @Test("空間更少時依序讓位：註記一行 → 建議一行 → 拿掉註記 → 拿掉建議")
    func shedsInPriorityOrder() {
        // 全部完整時的可分配高度 = 對話 + 293 + 68 = 對話 + 361。
        #expect(Self.arrange(conversation: 132 - 361 + 52 + 68) == ComposerAccessoryArrangement(note: .compact, suggestion: .full))
        #expect(Self.arrange(conversation: 132 - 361 + 52 + 52) == ComposerAccessoryArrangement(note: .compact, suggestion: .compact))
        #expect(Self.arrange(conversation: 132 - 361 + 52 + 52 - 1) == ComposerAccessoryArrangement(note: .hidden, suggestion: .compact))
        #expect(Self.arrange(conversation: 132 - 361 + 52 - 1) == ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden))
        // 全部拿掉仍不到最小高度：輸入列優先，不再讓。
        #expect(Self.arrange(conversation: -400) == ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden))
    }

    @Test("空間夠(iPad、實體鍵盤的快捷列)時鍵盤出現也完整顯示")
    func enoughRoomKeepsFullCards() {
        #expect(Self.arrange(conversation: 132) == .full)
        #expect(Self.arrange(conversation: 500) == .full)
    }

    @Test("收合後空間變大會恢復完整卡片;沒量過完整卡片時不冒險展開")
    func restoresWhenRoomReturns() {
        let collapsed = ComposerAccessoryArrangement(note: .compact, suggestion: .compact)
        #expect(Self.arrange(conversation: 600, current: collapsed) == .full)
        let unmeasured = ComposerAccessoryHeights(full: nil)
        #expect(Self.arrange(conversation: 600, current: collapsed, note: unmeasured, suggestion: unmeasured) == collapsed)
    }

    @Test("沒有註記與建議時沒有東西要讓;不知道對話高度時維持目前的顯示方式")
    func nothingToArrange() {
        #expect(Self.arrange(conversation: 6, note: nil, suggestion: nil) == .full)
        let collapsed = ComposerAccessoryArrangement(note: .compact, suggestion: .full)
        #expect(Self.arrange(conversation: nil, current: collapsed) == collapsed)
    }

    @Test("鍵盤出現時元素暫時不在(送出後重讀註記、換建議)仍維持讓位，回來時不先以完整卡片閃一下")
    func absentElementKeepsItsForm() {
        let collapsed = ComposerAccessoryArrangement(note: .compact, suggestion: .compact)
        #expect(Self.arrange(conversation: 300, current: collapsed, note: nil, suggestion: nil) == collapsed)
        // 回來時還沒量到完整卡片：維持一行。
        let unmeasured = ComposerAccessoryHeights(full: nil)
        #expect(Self.arrange(conversation: 300, current: collapsed, note: unmeasured, suggestion: nil) == collapsed)
    }

    @Test("完整卡片剛出現、還沒量到時先以一行估可分配高度：對話已經很矮就繼續讓位，不因量不到而停在收一行")
    func unmeasuredDisplayedCardCountsAsOneLine() {
        let unmeasured = ComposerAccessoryHeights(full: nil)
        // 可分配 = 對話 6 + 註記估 52 + 建議 68 = 126,不到 132:全部拿掉。
        #expect(Self.arrange(conversation: 6, note: unmeasured) == ComposerAccessoryArrangement(note: .hidden, suggestion: .hidden))
    }

    @Test("只有建議提示詞時，空間不夠就先收成一行")
    func suggestionOnly() {
        #expect(Self.arrange(conversation: 132 - 68 + 52, note: nil) == ComposerAccessoryArrangement(note: .full, suggestion: .compact))
    }

    @Test("遲滯(#498):剛好放得下完整卡片的邊界上不回到完整排法，多出一列觸控高度才恢復，避免兩種排法來回切換")
    func relaxingNeedsHysteresisMargin() {
        let collapsed = ComposerAccessoryArrangement(note: .compact, suggestion: .full)
        // 可分配 = 對話 + 52 + 68;完整排法要 361 + 最小 132,所以對話 373 剛好放得下。
        #expect(Self.arrange(conversation: 373, current: collapsed) == collapsed)
        #expect(Self.arrange(conversation: 373 + 43, current: collapsed) == collapsed)
        #expect(Self.arrange(conversation: 373 + 44, current: collapsed) == .full)
        // 往讓位方向沒有遲滯:完整排法時對話低於最小高度立刻收起。
        #expect(Self.arrange(conversation: 131, current: .full) == collapsed)
    }

    @Test("遲滯(#498):讓位後對話高度在邊界附近交替變化，排法不變;超過遲滯才換一次")
    func alternatingHeightsSettle() {
        let collapsed = ComposerAccessoryArrangement(note: .compact, suggestion: .full)
        var current = collapsed
        var changes = 0
        for height in [372.0, 373, 400, 373, 410, 372, 416] {
            let next = Self.arrange(conversation: height, current: current)
            if next != current { changes += 1; current = next }
        }
        #expect(changes == 0)
        #expect(Self.arrange(conversation: 417, current: current) == .full)
    }
}
