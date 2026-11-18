import Foundation

/// 終端機鍵盤輸入要送到遠端的一筆。
public enum TerminalInputSend: Sendable, Equatable {
    /// 照原樣送出的位元組(確認的文字、退格)。
    case bytes(Data)
    /// 經 `TerminalSessionModel.press(_:adding:)` 送出的按鍵(帶實體鍵盤按著的修飾鍵)。
    case key(TerminalKey, modifiers: TerminalModifiers)
    /// 經 `TerminalSessionModel.paste(_:bracketed:)` 送出的貼上內容。
    case paste(String)
}

/// 實體鍵盤的一顆鍵(與 UIKit 無關的描述;字元鍵是不含修飾的字元)。
public enum TerminalHardwareKey: Sendable, Equatable {
    case escape
    case tab
    case returnKey
    case deleteBackward
    case deleteForward
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case function(Int)
    case character(Character)
}

/// 實體鍵盤按鍵的去向。
public enum TerminalHardwareKeyHandling: Sendable, Equatable {
    /// 交給系統文字輸入(輸入法、`insertText`、`deleteBackward`)。
    case system
    case send(TerminalInputSend)
    /// 在本機捲一頁(同單指滑動的捲動),不送遠端。
    case scrollPage(TerminalInput.ScrollDirection)
}

/// 終端機輸入法的組字狀態：決定哪些輸入要送到遠端(組字期間一律不送)。
public struct TerminalComposition: Sendable, Equatable {
    /// 組字中的文字;沒有組字時是空字串。
    public private(set) var markedText = ""

    public init() {}

    public var isComposing: Bool { !markedText.isEmpty }

    /// 輸入法更新組字文字;空字串代表組字結束(不送出)。
    public mutating func setMarkedText(_ text: String) {
        markedText = text
    }

    /// 確認文字(選字、英文字母、Return):取代組字文字，只送確認的文字。換行一律送 CR。
    public mutating func insertText(_ text: String) -> [TerminalInputSend] {
        markedText = ""
        return Self.sendable(text)
    }

    /// 組字中只刪組字文字的最後一個字;沒有組字時送 DEL。
    public mutating func deleteBackward() -> [TerminalInputSend] {
        guard isComposing else { return [.bytes(Data([0x7F]))] }
        markedText.removeLast()
        return []
    }

    /// 系統要求結束組字：送出輸入法最後給的組字文字(常是已選好的字),但不送注音符號與聲調本身。
    public mutating func unmarkText() -> [TerminalInputSend] {
        let confirmed = String(String.UnicodeScalarView(markedText.unicodeScalars.filter { !Self.isZhuyin($0) }))
        markedText = ""
        return Self.sendable(confirmed)
    }

    /// Purrdr 自己結束組字(切換焦點等):放棄組字文字，不送出。
    public mutating func cancel() {
        markedText = ""
    }

    /// 按鍵列的一顆鍵：先放棄組字(不送出)再送該鍵。
    public mutating func pressKeyBarKey(_ key: TerminalKey) -> [TerminalInputSend] {
        cancel()
        return [.key(key, modifiers: [])]
    }

    /// 貼上：先放棄組字(不送出)再送貼上內容。
    public mutating func paste(_ text: String) -> [TerminalInputSend] {
        cancel()
        return text.isEmpty ? [] : [.paste(text)]
    }

    /// 實體鍵盤按鍵(`modifiers` 是按著的實體修飾鍵)。組字中一律交給輸入法。
    /// `scrollsPageLocally`:遠端沒開 alternate screen 與 application cursor 時，Page Up／Down 在本機捲一頁(同 SwiftTerm)。
    public func handle(
        _ key: TerminalHardwareKey, modifiers: TerminalModifiers, scrollsPageLocally: Bool = false
    ) -> TerminalHardwareKeyHandling {
        guard !isComposing else { return .system }
        let terminalKey: TerminalKey
        switch key {
        case .character(let character):
            guard !modifiers.isDisjoint(with: [.control, .alt]) else { return .system }
            terminalKey = .character(character)
        case .returnKey:
            return modifiers.contains(.alt) ? .send(.bytes(Data([0x1B, 0x0D]))) : .system
        case .deleteBackward:
            return modifiers.contains(.alt) ? .send(.bytes(Data([0x1B, 0x7F]))) : .system
        case .escape: terminalKey = .escape
        case .tab: terminalKey = .tab
        case .deleteForward: terminalKey = .deleteForward
        case .up: terminalKey = .up
        case .down: terminalKey = .down
        case .left: terminalKey = .left
        case .right: terminalKey = .right
        case .home: terminalKey = .home
        case .end: terminalKey = .end
        case .pageUp:
            guard !scrollsPageLocally else { return .scrollPage(.up) }
            terminalKey = .pageUp
        case .pageDown:
            guard !scrollsPageLocally else { return .scrollPage(.down) }
            terminalKey = .pageDown
        case .function(let number): terminalKey = .function(number)
        }
        return .send(.key(terminalKey, modifiers: modifiers))
    }

    private static func sendable(_ text: String) -> [TerminalInputSend] {
        guard !text.isEmpty else { return [] }
        let terminalText = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return [.bytes(Data(terminalText.utf8))]
    }

    /// 注音符號(含擴充)與注音聲調。
    private static func isZhuyin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3100...0x312F, 0x31A0...0x31BF, 0x02C7, 0x02CA, 0x02CB, 0x02D9: true
        default: false
        }
    }
}
