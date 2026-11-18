import Foundation

/// 輸入元件要送到遠端的一筆輸入。
public enum TerminalRemoteInput: Sendable, Equatable {
    /// 照原樣送出的位元組(確認的文字、退格)。
    case bytes(Data)
    /// 經 `TerminalSessionModel.press(_:adding:applicationCursor:)` 送出的按鍵(帶實體鍵盤按著的修飾鍵)。
    case key(TerminalKey, modifiers: TerminalModifiers, applicationCursor: Bool = false)
    /// 經 `TerminalSessionModel.paste(_:bracketed:)` 送出的貼上內容。
    case paste(String)
}

/// 實體鍵盤的一顆鍵(與 UIKit 無關)。終端機按鍵直接用 `TerminalKey`(字元鍵是不含修飾的字元);
/// Return 與刪除另列，因為沒有 Alt 時交給系統文字輸入。
public enum TerminalHardwareKey: Sendable, Equatable {
    case returnKey
    case deleteBackward
    case key(TerminalKey)
}

/// 實體鍵盤按鍵的去向。
public enum TerminalHardwareKeyHandling: Sendable, Equatable {
    /// 交給系統文字輸入(輸入法、`insertText`、`deleteBackward`)。
    case system
    case send(TerminalRemoteInput)
    /// 在本機捲一頁(同單指滑動的捲動),不送遠端。
    case scrollPage(TerminalInput.ScrollDirection)
    /// Page 鍵交給 herdr 依 Pane 狀態決定(捲主機 scrollback 或送給程式)。
    case sendPageKeyToHerdr(TerminalInput.ScrollDirection)
}

/// 遠端程式開的終端機模式，以及 App 看不看得到。
public enum TerminalProgramModes: Sendable, Equatable {
    /// 模擬器直接接 PTY(登入 Shell),看得到模式。
    case visible(applicationCursor: Bool, alternateScreen: Bool)
    /// herdr 的串流不轉送模式(Pane 終端機)。
    case hiddenByHerdr
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
    public mutating func insertText(_ text: String) -> [TerminalRemoteInput] {
        markedText = ""
        return Self.sendable(text)
    }

    /// 組字中只刪組字文字的最後一個字;沒有組字時送 DEL。
    public mutating func deleteBackward() -> [TerminalRemoteInput] {
        guard isComposing else { return [.bytes(Data([0x7F]))] }
        markedText.removeLast()
        return []
    }

    /// 系統要求結束組字：放棄組字文字，不送出(字元範圍分不出已選好的字與還在拼的音)。
    public mutating func unmarkText() -> [TerminalRemoteInput] {
        cancel()
        return []
    }

    /// Purrdr 自己結束組字(切換焦點等):放棄組字文字，不送出。
    public mutating func cancel() {
        markedText = ""
    }

    /// 按鍵列的一顆鍵：先放棄組字(不送出)再送該鍵。
    public mutating func pressKeyBarKey(_ key: TerminalKey, modes: TerminalProgramModes) -> [TerminalRemoteInput] {
        cancel()
        return [.key(key, modifiers: [], applicationCursor: modes.applicationCursor)]
    }

    /// 貼上：先放棄組字(不送出)再送貼上內容。
    public mutating func paste(_ text: String) -> [TerminalRemoteInput] {
        cancel()
        return text.isEmpty ? [] : [.paste(text)]
    }

    /// 實體鍵盤按鍵(`modifiers` 是按著的實體修飾鍵)。組字中一律交給輸入法。
    public func handle(
        _ key: TerminalHardwareKey, modifiers: TerminalModifiers, modes: TerminalProgramModes
    ) -> TerminalHardwareKeyHandling {
        guard !isComposing else { return .system }
        switch key {
        case .returnKey:
            return modifiers.contains(.alt) ? .send(.bytes(Data([0x1B, 0x0D]))) : .system
        case .deleteBackward:
            return modifiers.contains(.alt) ? .send(.bytes(Data([0x1B, 0x7F]))) : .system
        case .key(let terminalKey):
            switch terminalKey {
            case .character where modifiers.isDisjoint(with: [.control, .alt]):
                return .system
            case .pageUp:
                if let handling = modes.pageKeyHandling(.up) { return handling }
            case .pageDown:
                if let handling = modes.pageKeyHandling(.down) { return handling }
            default:
                break
            }
            return .send(.key(terminalKey, modifiers: modifiers, applicationCursor: modes.applicationCursor))
        }
    }

    private static func sendable(_ text: String) -> [TerminalRemoteInput] {
        guard !text.isEmpty else { return [] }
        let terminalText = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return [.bytes(Data(terminalText.utf8))]
    }
}

extension TerminalProgramModes {
    /// 方向鍵與 Home／End 要不要用 SS3;看不到模式時一律 CSI。
    var applicationCursor: Bool {
        switch self {
        case .visible(let applicationCursor, _): applicationCursor
        case .hiddenByHerdr: false
        }
    }

    /// Page Up／Down 不直接送 `CSI 5~` 時的去向：看不到模式交給 herdr,一般畫面本機捲一頁。
    func pageKeyHandling(_ direction: TerminalInput.ScrollDirection) -> TerminalHardwareKeyHandling? {
        switch self {
        case .hiddenByHerdr: .sendPageKeyToHerdr(direction)
        case .visible(false, false): .scrollPage(direction)
        case .visible: nil
        }
    }
}
