import Foundation

/// 嚴格的 JSON 語法檢查(RFC 8259)。
///
/// Foundation 的 `JSONSerialization` 會接受尾端逗號等寬鬆語法，但 Claude Code(`JSON.parse`)不接受;
/// 主機上的設定檔若連 Claude Code 自己都讀不了，我們就不該修改它。
package enum StrictJSON {
    package static let maximumDepth = 512

    package static func isValid(_ data: Data) -> Bool {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        guard parser.value(depth: 0) else { return false }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1
            return true
        }

        mutating func literal(_ text: String) -> Bool {
            let expected = Array(text.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else { return false }
            index += expected.count
            return true
        }

        mutating func value(depth: Int) -> Bool {
            guard depth < StrictJSON.maximumDepth else { return false }
            switch current {
            case UInt8(ascii: "{"): return object(depth: depth + 1)
            case UInt8(ascii: "["): return array(depth: depth + 1)
            case UInt8(ascii: "\""): return string()
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return number()
            }
        }

        mutating func object(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return true }
            while true {
                skipWhitespace()
                guard string() else { return false }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return false }
                skipWhitespace()
                guard value(depth: depth) else { return false }
                skipWhitespace()
                if consume(UInt8(ascii: "}")) { return true }
                guard consume(UInt8(ascii: ",")) else { return false }
            }
        }

        mutating func array(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return true }
            while true {
                skipWhitespace()
                guard value(depth: depth) else { return false }
                skipWhitespace()
                if consume(UInt8(ascii: "]")) { return true }
                guard consume(UInt8(ascii: ",")) else { return false }
            }
        }

        mutating func string() -> Bool {
            guard consume(UInt8(ascii: "\"")) else { return false }
            while let byte = current {
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return true
                case UInt8(ascii: "\\"):
                    guard let escaped = current else { return false }
                    index += 1
                    if escaped == UInt8(ascii: "u") {
                        for _ in 0..<4 {
                            guard let hex = current, isHexDigit(hex) else { return false }
                            index += 1
                        }
                    } else if !Array("\"\\/bfnrt".utf8).contains(escaped) {
                        return false
                    }
                case 0x00..<0x20:
                    return false
                default:
                    continue
                }
            }
            return false
        }

        mutating func number() -> Bool {
            _ = consume(UInt8(ascii: "-"))
            if consume(UInt8(ascii: "0")) {
                // 不允許前導零。
            } else {
                guard digits() else { return false }
            }
            if consume(UInt8(ascii: ".")), !digits() { return false }
            if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
                if !consume(UInt8(ascii: "+")) { _ = consume(UInt8(ascii: "-")) }
                guard digits() else { return false }
            }
            return true
        }

        mutating func digits() -> Bool {
            let start = index
            while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            return index > start
        }

        func isHexDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}
