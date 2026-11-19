/// 終端機按鍵列一顆鍵的外觀狀態(#241):停用變暗、按下有底、鎖定用中性填色。
struct TerminalKeyAppearance: Equatable, Sendable {
    /// 文字色：終端機強制深色，`primary` 即白字。
    enum Text: Sendable { case primary, dimmed }
    /// 鍵的底色，由淺到深。
    enum Fill: Sendable { case none, pressed, locked, lockedPressed }

    let text: Text
    let fill: Fill

    init(isLocked: Bool, isEnabled: Bool, isPressed: Bool) {
        text = isEnabled ? .primary : .dimmed
        let showsPress = isEnabled && isPressed
        switch (isLocked, showsPress) {
        case (true, true): fill = .lockedPressed
        case (true, false): fill = .locked
        case (false, true): fill = .pressed
        case (false, false): fill = .none
        }
    }
}
