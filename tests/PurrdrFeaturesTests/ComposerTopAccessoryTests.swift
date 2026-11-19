import PurrdrAgentFeatures
import Testing

/// 輸入框上方一次只顯示一樣：需要你 > 工作中 > 建議卡(#240)。
@Suite("輸入框上方的配件")
struct ComposerTopAccessoryTests {
    @Test("問題在等：顯示需要你，即使同時在工作中、也有建議")
    func needsYouWins() {
        let accessory = ComposerTopAccessory.choose(needsYou: true, isWorking: true, suggestion: "run the tests")
        #expect(accessory == .needsYou)
    }

    @Test("工作中：顯示工作中，不顯示建議")
    func workingBeatsSuggestion() {
        let accessory = ComposerTopAccessory.choose(needsYou: false, isWorking: true, suggestion: "run the tests")
        #expect(accessory == .working)
    }

    @Test("沒有問題、不在工作：有建議就顯示建議卡")
    func suggestionWhenIdle() {
        let accessory = ComposerTopAccessory.choose(needsYou: false, isWorking: false, suggestion: "run the tests")
        #expect(accessory == .suggestion("run the tests"))
    }

    @Test("什麼都沒有：不顯示")
    func nothing() {
        #expect(ComposerTopAccessory.choose(needsYou: false, isWorking: false, suggestion: nil) == nil)
    }
}
