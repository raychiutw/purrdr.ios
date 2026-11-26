#if canImport(UIKit)
import os
import PurrdrCore
import UIKit

/// 終端機的鍵盤輸入元件(#136):透明、放在遠端游標格子上的 first responder,自己處理輸入法組字。
/// 文件內容只有組字中的文字;確認的文字與按鍵經 `onSend` 送出，組字期間不送任何東西。
final class TerminalTextInputView: UIView, UITextInput {
    /// 要送到遠端的輸入。
    var onSend: ((TerminalRemoteInput) -> Void)?
    /// Page Up／Down 在本機捲一頁(登入 Shell 的一般畫面)。
    var onScrollPageLocally: ((TerminalInput.ScrollDirection) -> Void)?
    /// Page Up／Down 交給 herdr 決定(Pane 終端機)。
    var onSendPageKeyToHerdr: ((TerminalInput.ScrollDirection) -> Void)?
    /// 遠端程式目前的終端機模式(決定方向鍵編碼與 Page 鍵去向)。
    var programModes: () -> TerminalProgramModes = { .hiddenByHerdr }
    var onFocusChange: ((Bool) -> Void)?
    /// 組字文字或其中的選取改變(更新組字浮層)。
    var onCompositionChange: (() -> Void)?
    /// 終端機一格的寬度與畫面寬度(父視圖座標),給組字浮層與選字窗定位。
    var cellWidth: CGFloat = 8
    var screenWidth: CGFloat = 0
    /// 複製、全選等編輯動作交給終端機畫面(選取在它那邊)。
    weak var editActionTarget: UIResponder?

    private(set) var composition = TerminalComposition()
    /// 組字文字裡輸入法指定的選取範圍(UTF-16)。
    private(set) var markedSelection = NSRange(location: 0, length: 0) {
        didSet { onCompositionChange?() }
    }
    private var keyRepeat: Timer?
    /// 輸入法診斷紀錄：Console 篩 subsystem com.raychiu.purrdr、category ime;只記字元類別與長度。
    private static let imeLog = Logger(subsystem: "com.raychiu.purrdr", category: "ime")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Terminal Input")
        accessibilityIdentifier = "terminal.input"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 元件只有游標一格大：VoiceOver 的範圍以游標為中心撐到至少 44×44pt(HIG 觸控目標)。
    override var accessibilityFrame: CGRect {
        get {
            let cell = UIAccessibility.convertToScreenCoordinates(bounds, in: self)
            let minimum: CGFloat = 44
            return cell.insetBy(dx: min(0, (cell.width - minimum) / 2), dy: min(0, (cell.height - minimum) / 2))
        }
        set { super.accessibilityFrame = newValue }
    }

    /// 輸入元件的 tint 是系統文字色(#647):系統畫的輸入法指示膠囊(聽寫、「國」)、游標與選取反白都跟著,
    /// 深色白底深字、淺色黑底淺字。
    override var tintColor: UIColor! {
        get { UIColor.label }
        set { super.tintColor = newValue }
    }

    /// 觸控穿過去給終端機畫面(點連結、選取、捲動)。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    // MARK: - 焦點

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            trace(.becomeFirstResponder, markedBefore: composition.markedText)
            onFocusChange?(true)
        }
        return became
    }

    /// 離開焦點前先放棄組字，系統隨後的結束組字就不會把注音送出。
    override func resignFirstResponder() -> Bool {
        let markedBefore = composition.markedText
        changeComposition { $0.cancel() }
        trace(.resignFirstResponder, markedBefore: markedBefore)
        let resigned = super.resignFirstResponder()
        if resigned {
            stopKeyRepeat()
            onFocusChange?(false)
        }
        return resigned
    }

    /// Purrdr 自己結束組字：放棄組字文字並通知系統文字已變，不送出。
    func cancelComposition() {
        let markedBefore = composition.markedText
        changeComposition { $0.cancel() }
        trace(.cancelComposition, markedBefore: markedBefore)
    }

    /// 按鍵列的鍵：組字中先放棄組字再送。
    func pressKeyBarKey(_ key: TerminalKey) {
        let modes = programModes()
        let markedBefore = composition.markedText
        let sends = changeComposition { $0.pressKeyBarKey(key, modes: modes) }
        trace(.keyBarKey, markedBefore: markedBefore, sent: sends)
        send(sends)
    }

    /// 貼上(按鍵列、Command-V、編輯選單):組字中先放棄組字再送。
    func paste(text: String) {
        let markedBefore = composition.markedText
        let sends = changeComposition { $0.paste(text) }
        trace(.paste, markedBefore: markedBefore, sent: sends)
        send(sends)
    }

    /// 改組字狀態;組字文字因此被清掉時通知系統，輸入法才不會留著舊的組字。
    private func changeComposition<Result>(_ change: (inout TerminalComposition) -> Result) -> Result {
        guard composition.isComposing else { return change(&composition) }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        let result = change(&composition)
        markedSelection = NSRange(location: markedLength, length: 0)
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        return result
    }

    private func send(_ sends: [TerminalRemoteInput]) {
        sends.forEach { onSend?($0) }
    }

    /// 記一行輸入診斷(public:只有字元類別與長度，沒有原文)。
    private func trace(
        _ call: TerminalInputCall, text: String? = nil, selectedRange: NSRange? = nil,
        markedBefore: String, sent: [TerminalRemoteInput] = []
    ) {
        let line = TerminalInputTrace.line(
            call, text: text, selectedRange: selectedRange ?? markedSelection,
            markedBefore: markedBefore, markedAfter: composition.markedText, sent: sent
        )
        Self.imeLog.notice("\(line, privacy: .public)")
    }

    // MARK: - 編輯動作

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { paste(text: text) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:))
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if action != #selector(paste(_:)), let editActionTarget, editActionTarget.canPerformAction(action, withSender: sender) {
            return editActionTarget
        }
        return super.target(forAction: action, withSender: sender)
    }

    // MARK: - 實體鍵盤

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command),
                  let hardwareKey = TerminalHardwareKey(key)
            else {
                unhandled.insert(press)
                continue
            }
            switch composition.handle(hardwareKey, modifiers: TerminalModifiers(key.modifierFlags), modes: programModes()) {
            case .system:
                unhandled.insert(press)
            case .send(let input):
                onSend?(input)
                startKeyRepeat(input)
            case .scrollPage(let direction):
                onScrollPageLocally?(direction)
            case .sendPageKeyToHerdr(let direction):
                onSendPageKeyToHerdr?(direction)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopKeyRepeat()
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopKeyRepeat()
        super.pressesCancelled(presses, with: event)
    }

    /// 系統不會替自己處理的按鍵重複送 `pressesBegan`:按住 0.4 秒後每 0.1 秒重送(同 SwiftTerm)。
    private func startKeyRepeat(_ input: TerminalRemoteInput) {
        stopKeyRepeat()
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.4), interval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSend?(input) }
        }
        RunLoop.main.add(timer, forMode: .common)
        keyRepeat = timer
    }

    private func stopKeyRepeat() {
        keyRepeat?.invalidate()
        keyRepeat = nil
    }

    // MARK: - UIKeyInput

    /// 一律有字：文件是空的時候刪除鍵也要送到遠端。
    var hasText: Bool { true }

    func insertText(_ text: String) {
        let markedBefore = composition.markedText
        let sends = composition.insertText(text)
        markedSelection = NSRange(location: 0, length: 0)
        trace(.insertText, text: text, markedBefore: markedBefore, sent: sends)
        send(sends)
    }

    func deleteBackward() {
        let markedBefore = composition.markedText
        let sends = composition.deleteBackward()
        markedSelection = NSRange(location: markedLength, length: 0)
        trace(.deleteBackward, markedBefore: markedBefore, sent: sends)
        send(sends)
    }

    // MARK: - 輸入特性(終端機不要自動修正)

    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false

    // MARK: - UITextInput:文件 = 組字文字

    private var markedLength: Int { composition.markedText.utf16.count }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let markedBefore = composition.markedText
        defer { trace(.setMarkedText, text: markedText ?? "", selectedRange: selectedRange, markedBefore: markedBefore) }
        composition.setMarkedText(markedText ?? "")
        let length = markedLength
        let location = min(max(selectedRange.location, 0), length)
        markedSelection = NSRange(location: location, length: min(max(selectedRange.length, 0), length - location))
    }

    func unmarkText() {
        let markedBefore = composition.markedText
        let sends = composition.unmarkText()
        markedSelection = NSRange(location: 0, length: 0)
        trace(.unmarkText, markedBefore: markedBefore, sent: sends)
        send(sends)
    }

    var markedTextRange: UITextRange? {
        composition.isComposing ? TerminalTextRange(NSRange(location: 0, length: markedLength)) : nil
    }

    var markedTextStyle: [NSAttributedString.Key: Any]?

    var selectedTextRange: UITextRange? {
        get { TerminalTextRange(markedSelection) }
        set {
            guard let range = (newValue as? TerminalTextRange)?.range else { return }
            let length = markedLength
            let location = min(range.location, length)
            markedSelection = NSRange(location: location, length: min(range.length, length - location))
        }
    }

    func text(in range: UITextRange) -> String? {
        guard let range = (range as? TerminalTextRange)?.range else { return nil }
        let utf16 = Array(composition.markedText.utf16)
        let lower = min(range.location, utf16.count)
        let upper = min(range.location + range.length, utf16.count)
        return String(decoding: utf16[lower..<upper], as: UTF16.self)
    }

    /// 系統直接換掉文件的一段:組字中改組字文字，否則當成確認的文字送出。
    func replace(_ range: UITextRange, withText text: String) {
        trace(.replace, text: text, selectedRange: (range as? TerminalTextRange)?.range, markedBefore: composition.markedText)
        guard composition.isComposing, let range = (range as? TerminalTextRange)?.range else {
            insertText(text)
            return
        }
        let replaced = (composition.markedText as NSString).replacingCharacters(
            in: NSRange(location: min(range.location, markedLength), length: min(range.length, markedLength - min(range.location, markedLength))),
            with: text
        )
        setMarkedText(replaced, selectedRange: NSRange(location: (replaced as NSString).length, length: 0))
    }

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(markedLength) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition, let to = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        let target = position.offset + offset
        return (0...markedLength).contains(target) ? TerminalTextPosition(target) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = (position as? TerminalTextPosition)?.offset ?? 0
        let rhs = (other as? TerminalTextPosition)?.offset ?? 0
        return lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? TerminalTextPosition)?.offset ?? 0) - ((from as? TerminalTextPosition)?.offset ?? 0)
    }

    weak var inputDelegate: UITextInputDelegate?

    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let end = direction == .left || direction == .up ? beginningOfDocument : endOfDocument
        return textRange(from: position, to: end)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// 組字浮層的版面(父視圖座標);輸入元件本身放在游標格子上。
    var compositionLayout: TerminalCompositionLayout {
        TerminalCompositionLayout(
            markedText: composition.markedText,
            cursor: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            cellWidth: cellWidth,
            screenWidth: screenWidth
        )
    }

    /// 選字窗對齊組字段;沒有組字時是游標格子。
    func firstRect(for range: UITextRange) -> CGRect {
        let range = (range as? TerminalTextRange)?.range ?? NSRange(location: 0, length: 0)
        return localRect(compositionLayout.rect(utf16Location: range.location, length: range.length))
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        localRect(compositionLayout.caret(utf16Offset: (position as? TerminalTextPosition)?.offset ?? 0))
    }

    private func localRect(_ box: TerminalCompositionLayout.Box) -> CGRect {
        CGRect(x: box.x - frame.minX, y: box.y - frame.minY, width: box.width, height: box.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }
}

/// 組字文字裡的位置(UTF-16 offset)。
final class TerminalTextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}

final class TerminalTextRange: UITextRange {
    let range: NSRange

    init(_ range: NSRange) {
        self.range = range
    }

    override var start: UITextPosition { TerminalTextPosition(range.location) }
    override var end: UITextPosition { TerminalTextPosition(range.location + range.length) }
    override var isEmpty: Bool { range.length == 0 }
}

extension TerminalHardwareKey {
    /// 實體鍵盤的 UIKey;修飾鍵本身與不認得的鍵回傳 `nil`(交給系統)。
    @MainActor
    init?(_ key: UIKey) {
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: self = .returnKey
        case .keyboardDeleteOrBackspace: self = .deleteBackward
        default:
            guard let terminalKey = TerminalKey(key) else { return nil }
            self = .key(terminalKey)
        }
    }
}

extension TerminalKey {
    /// 終端機按鍵對應的 UIKey;字元鍵取不含修飾的字元。
    @MainActor
    init?(_ key: UIKey) {
        switch key.keyCode {
        case .keyboardEscape: self = .escape
        case .keyboardTab: self = .tab
        case .keyboardDeleteForward: self = .deleteForward
        case .keyboardUpArrow: self = .up
        case .keyboardDownArrow: self = .down
        case .keyboardLeftArrow: self = .left
        case .keyboardRightArrow: self = .right
        case .keyboardHome: self = .home
        case .keyboardEnd: self = .end
        case .keyboardPageUp: self = .pageUp
        case .keyboardPageDown: self = .pageDown
        case .keyboardF1: self = .function(.f1)
        case .keyboardF2: self = .function(.f2)
        case .keyboardF3: self = .function(.f3)
        case .keyboardF4: self = .function(.f4)
        case .keyboardF5: self = .function(.f5)
        case .keyboardF6: self = .function(.f6)
        case .keyboardF7: self = .function(.f7)
        case .keyboardF8: self = .function(.f8)
        case .keyboardF9: self = .function(.f9)
        case .keyboardF10: self = .function(.f10)
        case .keyboardF11: self = .function(.f11)
        case .keyboardF12: self = .function(.f12)
        default:
            guard let character = key.charactersIgnoringModifiers.first, key.charactersIgnoringModifiers.count == 1 else { return nil }
            self = .character(character)
        }
    }
}

extension TerminalModifiers {
    init(_ flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.alternate) { insert(.alt) }
        if flags.contains(.shift) { insert(.shift) }
    }
}
#endif
