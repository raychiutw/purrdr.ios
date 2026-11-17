import Foundation

/// Claude Code 的建議提示詞(prompt suggestion,#121):Claude 回完一輪後，輸入列裡灰色的「下一句」。
///
/// Claude Code 沒有讀出建議文字的程式化介面，只能從含 ANSI 的 pane 畫面(`pane.read` visible、`.ansi`)辨識。
/// 判斷依據取自真實錄製(Claude Code 2.1.326,見 `PromptSuggestionTests`):
///
/// - 輸入列是以 `❯` + NBSP(U+00A0)開頭的那一行;已送出的 prompt 是 `❯` + 一般空白，不會被誤認。
/// - 建議整段是 SGR 2(dim);使用者打的字沒有 dim,只要有一個非 dim 的可見字元就不是建議。
/// - session 剛開時輸入列的 dim 範例一律是 `Try "…"`,排除。
/// - 2.1.326 之前可能出現 `<signal type="empty" />` 這類裸標籤(CHANGELOG),排除。
///
/// 只適用 Claude Code 的畫面。
public enum PromptSuggestion {
    /// 輸入列的開頭：`❯` + NBSP。
    static let inputPrefix = "❯\u{00A0}"

    /// 從含 ANSI 的畫面找出建議文字;沒有建議回 `nil`。
    public static func detect(screen: String) -> String? {
        let lines = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.hasPrefix(inputPrefix) }) else { return nil }
        guard let text = dimText(String(lines[index].dropFirst(inputPrefix.count))) else { return nil }
        if text.isEmpty || isSessionStartExample(text) || isBareTag(text) { return nil }
        return text
    }

    /// 整段只是一個自我結束的標籤(`<signal type="empty" />`);文字中間提到標籤的不算。
    static func isBareTag(_ text: String) -> Bool {
        text.wholeMatch(of: /<[A-Za-z][^<>]*\/>/) != nil
    }

    /// session 剛開時的範例:`Try "…"`(整段被引號包住)。
    static func isSessionStartExample(_ text: String) -> Bool {
        text.hasPrefix("Try \"") && text.hasSuffix("\"")
    }

    /// 一行的可見文字，前提是所有非空白字元都是 dim;有任何非 dim 的可見字元回 `nil`。
    static func dimText(_ line: String) -> String? {
        var text = ""
        var dim = false
        var rest = Substring(line)
        while let first = rest.first {
            if first == "\u{1B}" {
                guard let (parameters, remainder) = csi(rest) else { return nil }
                rest = remainder
                if let parameters { dim = applySGR(parameters, dim: dim) }
                continue
            }
            if !first.isWhitespace, !dim { return nil }
            text.append(first)
            rest = rest.dropFirst()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 一個 CSI 序列:SGR(`m` 結尾)回傳參數，其他 CSI 回傳 `nil` 參數;不是 CSI 時整個回 `nil`。
    private static func csi(_ text: Substring) -> (String?, Substring)? {
        var rest = text.dropFirst()
        guard rest.first == "[" else { return nil }
        rest = rest.dropFirst()
        var parameters = ""
        while let character = rest.first {
            rest = rest.dropFirst()
            guard let scalar = character.unicodeScalars.first?.value else { return nil }
            if (0x40...0x7E).contains(scalar) {
                return (character == "m" ? parameters : nil, rest)
            }
            parameters.append(character)
        }
        return nil
    }

    /// 套用 SGR 參數，只追蹤 dim:`0`／空 重設、`2` 開、`22` 關;38／48 的延伸色參數跳過。
    private static func applySGR(_ parameters: String, dim: Bool) -> Bool {
        var dim = dim
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            switch codes[index] {
            case 0: dim = false
            case 2: dim = true
            case 22: dim = false
            case 38, 48, 58:
                if index + 1 < codes.count, codes[index + 1] == 5 { index += 2 } else if index + 1 < codes.count, codes[index + 1] == 2 { index += 4 }
            default: break
            }
            index += 1
        }
        return dim
    }
}
