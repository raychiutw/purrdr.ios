import Foundation

/// 一行一則的 JSON 訊息(JSON Lines)。
public enum JSONLines {
    /// 行與行之間的換行。
    public static let separator: UInt8 = 0x0A

    /// 從 `buffer` 取出第一個完整的行(不含換行);還沒有完整的行時是 `nil`。
    public static func takeLine(from buffer: inout Data) -> Data? {
        guard let newline = buffer.firstIndex(of: separator) else { return nil }
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }
}
