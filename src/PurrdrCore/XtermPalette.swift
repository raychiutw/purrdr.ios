/// xterm 256 色調色盤的固定部分(與 UIKit 無關)。
public enum XtermPalette {
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

    /// 16–255 號色;0–15 由主題決定，回傳 `nil`。
    public static func color(_ code: UInt8) -> RGB? {
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
