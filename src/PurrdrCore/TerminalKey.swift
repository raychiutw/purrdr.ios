import Foundation

/// 終端機按鍵列上的一顆鍵(或軟體鍵盤打出的一個字元)。
///
/// 方向鍵與 Home／End 依遠端的 application cursor 模式(DECCKM)送 SS3(`ESC O A`)或 CSI(`ESC [ A`)。
public enum TerminalKey: Sendable, Equatable {
    case escape
    case tab
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case deleteForward
    /// F1–F12(實體鍵盤)。
    case function(TerminalFunctionKey)
    case character(Character)

    /// 依修飾鍵與 application cursor 模式編碼成要送給主機的 bytes(行為規格 §6.4;實體鍵盤才有的鍵用 xterm 編碼)。
    public func bytes(modifiers: TerminalModifiers = [], applicationCursor: Bool = false) -> Data {
        let escape: UInt8 = 0x1B
        let altPrefix = modifiers.contains(.alt) ? Data([escape]) : Data()
        // 修飾參數 = 1 + Shift(1) + Alt(2) + Ctrl(4)
        let parameter = 1 + (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.alt) ? 2 : 0)
            + (modifiers.contains(.control) ? 4 : 0)
        switch self {
        case .escape:
            return altPrefix + [escape]
        case .tab:
            return altPrefix + (modifiers.contains(.shift) ? Data("\u{1B}[Z".utf8) : Data([0x09]))
        case .up, .down, .left, .right, .home, .end:
            let final = cursorFinal
            guard parameter > 1 else { return Data([escape, UInt8(ascii: applicationCursor ? "O" : "["), final]) }
            return Data("\u{1B}[1;\(parameter)".utf8) + [final]
        case .pageUp:
            return Self.tilde(5, parameter: parameter)
        case .pageDown:
            return Self.tilde(6, parameter: parameter)
        case .deleteForward:
            return Self.tilde(3, parameter: parameter)
        case .function(let functionKey):
            return functionKey.bytes(parameter: parameter)
        case .character(let character):
            let utf8 = Data(String(character).utf8)
            guard modifiers.contains(.control), let control = Self.control(character) else { return altPrefix + utf8 }
            return altPrefix + [control]
        }
    }

    /// `CSI <number> ~`,有修飾時 `CSI <number>;<parameter> ~`。
    fileprivate static func tilde(_ number: Int, parameter: Int) -> Data {
        Data((parameter > 1 ? "\u{1B}[\(number);\(parameter)~" : "\u{1B}[\(number)~").utf8)
    }

    private var cursorFinal: UInt8 {
        switch self {
        case .up: UInt8(ascii: "A")
        case .down: UInt8(ascii: "B")
        case .right: UInt8(ascii: "C")
        case .left: UInt8(ascii: "D")
        case .home: UInt8(ascii: "H")
        default: UInt8(ascii: "F")
        }
    }

    /// 字元加 Ctrl 的控制字元。沒有對應的回傳 `nil`(照原字元送)。
    private static func control(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return ascii - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return ascii - UInt8(ascii: "A") + 1
        default: break
        }
        switch character {
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1B
        case "\\", "|", "4": return 0x1C
        case "]", "5": return 0x1D
        case "^", "~", "6": return 0x1E
        case "_", "-", "/", "7": return 0x1F
        case "?", "8": return 0x7F
        default: return nil
        }
    }
}

/// 功能鍵 F1–F12。
public enum TerminalFunctionKey: Int, Sendable, CaseIterable {
    case f1 = 1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// F1–F4 是 SS3 `P`–`S`(帶修飾時 `CSI 1;<參數>`),F5–F12 是 `CSI <n> ~`。
    fileprivate func bytes(parameter: Int) -> Data {
        switch self {
        case .f1, .f2, .f3, .f4:
            let final = UInt8(ascii: "P") + UInt8(rawValue - 1)
            guard parameter > 1 else { return Data([0x1B, UInt8(ascii: "O"), final]) }
            return Data("\u{1B}[1;\(parameter)".utf8) + [final]
        case .f5: return TerminalKey.tilde(15, parameter: parameter)
        case .f6: return TerminalKey.tilde(17, parameter: parameter)
        case .f7: return TerminalKey.tilde(18, parameter: parameter)
        case .f8: return TerminalKey.tilde(19, parameter: parameter)
        case .f9: return TerminalKey.tilde(20, parameter: parameter)
        case .f10: return TerminalKey.tilde(21, parameter: parameter)
        case .f11: return TerminalKey.tilde(23, parameter: parameter)
        case .f12: return TerminalKey.tilde(24, parameter: parameter)
        }
    }
}

/// 黏著修飾鍵。
public struct TerminalModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = TerminalModifiers(rawValue: 1 << 0)
    public static let alt = TerminalModifiers(rawValue: 1 << 1)
    /// 只有實體鍵盤會帶(游標類鍵、功能鍵、Shift-Tab)。
    public static let shift = TerminalModifiers(rawValue: 1 << 2)

    /// 以這組黏著修飾鍵加上實體修飾鍵編碼一顆鍵，並放開黏著修飾鍵(Pane 終端機與登入 Shell 共用)。
    public mutating func release(encoding key: TerminalKey, adding extra: TerminalModifiers, applicationCursor: Bool) -> Data {
        defer { self = [] }
        return key.bytes(modifiers: union(extra), applicationCursor: applicationCursor)
    }
}
