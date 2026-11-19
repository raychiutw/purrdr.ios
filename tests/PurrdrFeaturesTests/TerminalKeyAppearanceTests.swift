@testable import PurrdrFeatures
import Testing

/// 終端機按鍵列每顆鍵的外觀狀態(#241、hig-audit 11.2、11.3)。
@Suite("終端機按鍵列外觀")
struct TerminalKeyAppearanceTests {
    @Test("可用的一般鍵：主要色文字、沒有底")
    func enabledKeyUsesPrimaryTextWithoutFill() {
        let appearance = TerminalKeyAppearance(isLocked: false, isEnabled: true, isPressed: false)

        #expect(appearance.text == .primary)
        #expect(appearance.fill == .none)
    }

    @Test("停用時文字變暗")
    func disabledKeyDimsText() {
        let appearance = TerminalKeyAppearance(isLocked: false, isEnabled: false, isPressed: false)

        #expect(appearance.text == .dimmed)
    }

    @Test("按下時有按壓底")
    func pressedKeyShowsPressedFill() {
        let appearance = TerminalKeyAppearance(isLocked: false, isEnabled: true, isPressed: true)

        #expect(appearance.fill == .pressed)
    }

    @Test("鎖定的修飾鍵用中性填色與主要色文字，不是白底黑字")
    func lockedModifierUsesNeutralFill() {
        let appearance = TerminalKeyAppearance(isLocked: true, isEnabled: true, isPressed: false)

        #expect(appearance.fill == .locked)
        #expect(appearance.text == .primary)
    }

    @Test("鎖定中再按下，底色比鎖定更深")
    func pressedLockedModifierShowsStrongerFill() {
        let appearance = TerminalKeyAppearance(isLocked: true, isEnabled: true, isPressed: true)

        #expect(appearance.fill == .lockedPressed)
    }

    @Test("停用時不顯示按壓底")
    func disabledKeyIgnoresPress() {
        let appearance = TerminalKeyAppearance(isLocked: false, isEnabled: false, isPressed: true)

        #expect(appearance.fill == .none)
    }
}
