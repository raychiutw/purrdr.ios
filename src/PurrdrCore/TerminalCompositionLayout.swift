/// 組字浮層在終端機畫面上的版面(與 UIKit 無關;座標單位是 point)。
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

    public init(markedText: String, cursor: Box, cellWidth: Double, screenWidth: Double) {
        overlay = cursor
    }

    /// 組字文字一段(UTF-16 範圍)的矩形。
    public func rect(utf16Location: Int, length: Int) -> Box {
        overlay
    }

    /// 組字文字裡插入點(UTF-16 位置)的矩形。
    public func caret(utf16Offset: Int) -> Box {
        overlay
    }

    /// 文字在終端機上佔的格數。
    public static func columns(of text: String) -> Int {
        0
    }

    /// xterm 256 色的 16–255;0–15 由主題決定，回傳 `nil`。
    public static func xterm256(_ code: UInt8) -> RGB? {
        nil
    }
}
