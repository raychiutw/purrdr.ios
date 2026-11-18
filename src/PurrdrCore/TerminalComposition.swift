import Foundation

/// 終端機鍵盤輸入要送到遠端的一筆。
public enum TerminalInputSend: Sendable, Equatable {
    /// 照原樣送出的位元組(確認的文字、退格)。
    case bytes(Data)
    /// 經 `TerminalSessionModel.press(_:adding:)` 送出的按鍵(帶實體鍵盤按著的修飾鍵)。
    case key(TerminalKey, modifiers: TerminalModifiers)
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
}

/// 終端機輸入法的組字狀態：決定哪些輸入要送到遠端(組字期間一律不送)。
public struct TerminalComposition: Sendable, Equatable {
    /// 組字中的文字;沒有組字時是空字串。
    public private(set) var markedText = ""

    public init() {}

    public var isComposing: Bool { !markedText.isEmpty }

    /// 輸入法更新組字文字;空字串代表組字結束(不送出)。
    public mutating func setMarkedText(_ text: String) {}

    /// 確認文字(選字、英文字母、Return)。
    public mutating func insertText(_ text: String) -> [TerminalInputSend] { [] }

    public mutating func deleteBackward() -> [TerminalInputSend] { [] }

    /// 系統要求結束組字。
    public mutating func unmarkText() -> [TerminalInputSend] { [] }

    /// Purrdr 自己結束組字(切換焦點等):放棄組字文字，不送出。
    public mutating func cancel() {}

    /// 實體鍵盤按鍵(`modifiers` 是按著的實體修飾鍵)。
    public func handle(_ key: TerminalHardwareKey, modifiers: TerminalModifiers) -> TerminalHardwareKeyHandling {
        .system
    }
}
