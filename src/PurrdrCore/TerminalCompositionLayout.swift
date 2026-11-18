/// 組字浮層在終端機畫面上的版面(與 UIKit 無關;座標單位是 point)。
/// 浮層從游標格子開始、每格 `cellWidth`,寬字元佔兩格;超出畫面右緣時往左移。
public struct TerminalCompositionLayout: Sendable, Equatable {
    public struct Box: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct RGB: Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// 浮層的位置與大小。
    public let overlay: Box
    private let markedText: String
    private let cellWidth: Double

    public init(markedText: String, cursor: Box, cellWidth: Double, screenWidth: Double) {
        self.markedText = markedText
        self.cellWidth = cellWidth
        let width = Double(Self.columns(of: markedText)) * cellWidth
        let x = cursor.x + width > screenWidth ? max(screenWidth - width, 0) : cursor.x
        overlay = Box(x: x, y: cursor.y, width: width, height: cursor.height)
    }

    /// 組字文字一段(UTF-16 範圍)的矩形;空範圍給一格寬。
    public func rect(utf16Location: Int, length: Int) -> Box {
        let start = columns(beforeUTF16Offset: utf16Location)
        let end = columns(beforeUTF16Offset: utf16Location + max(length, 0))
        let width = end > start ? Double(end - start) * cellWidth : cellWidth
        return Box(x: overlay.x + Double(start) * cellWidth, y: overlay.y, width: width, height: overlay.height)
    }

    /// 組字文字裡插入點(UTF-16 位置)的矩形。
    public func caret(utf16Offset: Int) -> Box {
        let x = overlay.x + Double(columns(beforeUTF16Offset: utf16Offset)) * cellWidth
        return Box(x: x, y: overlay.y, width: 2, height: overlay.height)
    }

    /// UTF-16 位置之前的格數;落在字元中間時算到該字元之前，超出範圍時算到結尾。
    private func columns(beforeUTF16Offset offset: Int) -> Int {
        var consumed = 0
        var columns = 0
        for character in markedText {
            let length = character.utf16.count
            guard consumed + length <= offset else { break }
            consumed += length
            columns += Self.columns(of: character)
        }
        return columns
    }

    /// 文字在終端機上佔的格數。
    public static func columns(of text: String) -> Int {
        text.reduce(0) { $0 + columns(of: $1) }
    }

    /// 一個字元的格數：東亞寬字元與 emoji 兩格，只有組合記號的字元零格，其他一格。
    /// 變體選擇符同 SwiftTerm:emoji 基底帶 VS15 一格、帶 VS16 兩格，其他基底不受影響。
    static func columns(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.allSatisfy(isZeroWidth) { return 0 }
        if first.properties.isEmoji, !isWide(first.value) {
            if scalars.contains("\u{FE0E}") { return 1 }
            if scalars.contains("\u{FE0F}") { return 2 }
        }
        return isWide(first.value) || first.properties.isEmojiPresentation ? 2 : 1
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: true
        default: false
        }
    }

    /// East Asian Wide／Fullwidth 的主要區段(與終端機的 wcwidth 一致)。
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }

    /// xterm 256 色的 16–255;0–15 由主題決定，回傳 `nil`。
    public static func xterm256(_ code: UInt8) -> RGB? {
        switch code {
        case 0..<16:
            return nil
        case 16..<232:
            let index = Int(code) - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return RGB(red: levels[index / 36], green: levels[(index / 6) % 6], blue: levels[index % 6])
        default:
            let gray = UInt8(8 + (Int(code) - 232) * 10)
            return RGB(red: gray, green: gray, blue: gray)
        }
    }
}
