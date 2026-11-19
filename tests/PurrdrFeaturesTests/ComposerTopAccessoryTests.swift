import PurrdrAgentFeatures
import Testing

/// 輸入框上方一次只顯示一樣：需要你 > 工作中(停止列,#220) > 建議卡(#240)。
@Suite("輸入框上方的配件")
struct ComposerTopAccessoryTests {
    @Test("問題在等：顯示需要你，即使同時在工作中、也有建議")
    func needsYouWins() {
        let accessory = ComposerTopAccessory.choose(needsYou: true, isWorking: true, showsStopBar: true, suggestion: "run the tests")
        #expect(accessory == .needsYou)
    }

    @Test("工作中：顯示工作中，不顯示建議")
    func workingBeatsSuggestion() {
        let accessory = ComposerTopAccessory.choose(needsYou: false, isWorking: true, showsStopBar: true, suggestion: "run the tests")
        #expect(accessory == .working)
    }

    @Test("沒有問題、不在工作：有建議就顯示建議卡")
    func suggestionWhenIdle() {
        let accessory = ComposerTopAccessory.choose(needsYou: false, isWorking: false, showsStopBar: false, suggestion: "run the tests")
        #expect(accessory == .suggestion("run the tests"))
    }

    @Test("什麼都沒有：不顯示")
    func nothing() {
        #expect(ComposerTopAccessory.choose(needsYou: false, isWorking: false, showsStopBar: false, suggestion: nil) == nil)
    }

    @Test("停止列還在(例如「已停止」那 2 秒)但已不在工作：仍算工作中，不顯示建議")
    func stopBarResultKeepsWorkingSlot() {
        let accessory = ComposerTopAccessory.choose(needsYou: false, isWorking: false, showsStopBar: true, suggestion: "run the tests")
        #expect(accessory == .working)
    }

    @Test("問題在等時停止列只剩「需要你」結果：算需要你")
    func needsYouWinsOverStopBar() {
        let accessory = ComposerTopAccessory.choose(needsYou: true, isWorking: false, showsStopBar: true, suggestion: nil)
        #expect(accessory == .needsYou)
    }

    @Test("You should know 完整卡片與建議卡不同時出現：註記優先，建議卡收起")
    func fullNoteHidesSuggestion() {
        let shown = ComposerAccessoryArrangement.full.sharingTopSlot(hasNote: true)
        #expect(shown == ComposerAccessoryArrangement(note: .full, suggestion: .hidden))
    }

    @Test("註記收成一行(鍵盤讓位)或被拿掉時，建議卡照讓位規則顯示")
    func compactNoteKeepsSuggestion() {
        let compactNote = ComposerAccessoryArrangement(note: .compact, suggestion: .full)
        #expect(compactNote.sharingTopSlot(hasNote: true) == compactNote)
        let hiddenNote = ComposerAccessoryArrangement(note: .hidden, suggestion: .compact)
        #expect(hiddenNote.sharingTopSlot(hasNote: true) == hiddenNote)
    }

    @Test("沒有註記：建議卡照讓位規則顯示")
    func noNoteKeepsSuggestion() {
        #expect(ComposerAccessoryArrangement.full.sharingTopSlot(hasNote: false) == .full)
    }
}
