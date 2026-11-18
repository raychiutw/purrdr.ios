import Foundation

/// 終端機按鍵列上的一顆鍵(或軟體鍵盤打出的一個字元)。
///
/// App 看不到遠端程式的終端機模式(herdr 的串流不轉送 DECCKM),所以方向鍵固定送 CSI 形式(`ESC [ A`)。
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
    /// F1–F12(實體鍵盤);其他編號不送。
    case function(Int)
    case character(Character)

    /// 依修飾鍵編碼成要送給主機的 bytes(行為規格 §6.4)。
    public func bytes(modifiers: TerminalModifiers = []) -> Data {
        let escape: UInt8 = 0x1B
        let altPrefix = modifiers.contains(.alt) ? Data([escape]) : Data()
        switch self {
        case .escape:
            return altPrefix + [escape]
        case .tab:
            return altPrefix + [0x09]
        case .up, .down, .left, .right, .home, .end:
            let final = cursorFinal
            guard !modifiers.isEmpty else { return Data([escape, UInt8(ascii: "["), final]) }
            // 修飾參數 = 1 + Alt(2) + Ctrl(4)
            let parameter = 1 + (modifiers.contains(.alt) ? 2 : 0) + (modifiers.contains(.control) ? 4 : 0)
            return Data("\u{1B}[1;\(parameter)".utf8) + [final]
        case .pageUp, .pageDown, .deleteForward, .function:
            return Data()
        case .character(let character):
            let utf8 = Data(String(character).utf8)
            guard modifiers.contains(.control), let control = Self.control(character) else { return altPrefix + utf8 }
            return altPrefix + [control]
        }
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

/// 黏著修飾鍵。
public struct TerminalModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = TerminalModifiers(rawValue: 1 << 0)
    public static let alt = TerminalModifiers(rawValue: 1 << 1)
    /// 只有實體鍵盤會帶(游標類鍵、功能鍵、Shift-Tab)。
    public static let shift = TerminalModifiers(rawValue: 1 << 2)
}
