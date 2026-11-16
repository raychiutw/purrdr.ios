import Foundation

/// 把 Windows 主機的錯誤輸出整理成給人看的文字(#6 待辦 5)。只處理顯示;判斷一律靠 exit code(行為規格 §3.2)。
///
/// - herdr(Rust)的 `Error: Custom { kind: …, error: "…" }`:取出 `error` 字串並還原跳脫(路徑的 `\\` → `\`)。
/// - PowerShell 的 CLIXML(`#< CLIXML` 開頭):只留 `<S S="Error">` 的文字,`_x000D__x000A_` 這類編碼還原、XML 實體解開。
/// - 系統訊息依 Windows 語系在地化(例如「系統找不到指定的檔案。」),原樣保留。
public enum WindowsErrorText {
    public static func readable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#< CLIXML") { return clixml(trimmed) }
        if let inner = rustDebugError(trimmed) { return inner }
        return trimmed
    }

    private static func clixml(_ text: String) -> String {
        var pieces: [String] = []
        var rest = Substring(text)
        let open = #"<S S="Error">"#
        while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: "</S>") {
            pieces.append(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        let joined = decodeXMLText(pieces.joined()).replacingOccurrences(of: "\r\n", with: "\n")
        return joined.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .init(charactersIn: " \r")).isEmpty ? "" : String($0) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `_xHHHH_`(PowerShell 序列化的控制字元)與 XML 實體。
    private static func decodeXMLText(_ text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let character = rest.first {
            if character == "_", rest.count >= 7, rest.dropFirst().hasPrefix("x"),
               let scalar = UInt32(rest.dropFirst(2).prefix(4), radix: 16), rest.dropFirst(6).first == "_",
               let unicode = Unicode.Scalar(scalar) {
                output.unicodeScalars.append(unicode)
                rest = rest.dropFirst(7)
                continue
            }
            if character == "&", let semicolon = rest.firstIndex(of: ";") {
                let entity = rest[rest.index(after: rest.startIndex)..<semicolon]
                let replacement: String? = switch entity {
                case "lt": "<"
                case "gt": ">"
                case "amp": "&"
                case "quot": "\""
                case "apos": "'"
                default: nil
                }
                if let replacement {
                    output += replacement
                    rest = rest[rest.index(after: semicolon)...]
                    continue
                }
            }
            output.append(character)
            rest = rest.dropFirst()
        }
        return output
    }

    /// `Error: Custom { kind: NotFound, error: "…" }` 的 `error` 字串(Rust 的字串跳脫)。
    private static func rustDebugError(_ text: String) -> String? {
        guard text.hasPrefix("Error: "), let marker = text.range(of: #"error: ""#) else { return nil }
        var output = ""
        var rest = text[marker.upperBound...]
        while let character = rest.first {
            rest = rest.dropFirst()
            switch character {
            case "\"":
                return output
            case "\\":
                guard let escaped = rest.first else { return nil }
                rest = rest.dropFirst()
                switch escaped {
                case "n": output += "\n"
                case "r": output += "\r"
                case "t": output += "\t"
                default: output.append(escaped)
                }
            default:
                output.append(character)
            }
        }
        return nil
    }
}
