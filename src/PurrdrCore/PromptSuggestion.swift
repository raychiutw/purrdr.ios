import Foundation

/// Claude Code 的建議提示詞(prompt suggestion,#121):Claude 回完一輪後，輸入列裡灰色的「下一句」。
///
/// Claude Code 沒有讀出建議文字的程式化介面，只能從含 ANSI 的 pane 畫面(`pane.read` visible、`.ansi`)辨識。
/// 判斷依據取自真實錄製(Claude Code 2.1.326,見 `PromptSuggestionTests`):
///
/// - 輸入框在上下兩條 `─` 分隔線之間，第一行以 `❯` + NBSP(U+00A0)開頭;已送出的 prompt 是 `❯` + 一般空白，不會被誤認。
///   `❯` 前面的跳脫序列(SGR、游標)不影響辨識。
/// - 建議整段是 SGR 2(dim);使用者打的字沒有 dim,只要有一個非 dim 的可見字元就不是建議。
/// - 太長換行時，後續行接在輸入框裡(到下緣分隔線為止),同樣要整段 dim,以一個空白接起來。
///   找不到下緣分隔線(畫面不完整)時不顯示——寧可沒有，也不給半句。
/// - session 剛開時輸入列的 dim 範例一律是 `Try "…"`,排除。
/// - 2.1.326 之前可能出現 `<signal type="empty" />` 這類裸標籤(CHANGELOG),排除。
///
/// 只適用 Claude Code 的畫面。
public enum PromptSuggestion {
    /// 輸入列的開頭:`❯` + NBSP。
    static let inputPrefix = "❯\u{00A0}"

    /// 一個可見字元與它是否 dim。
    struct Cell {
        var character: Character
        var dim: Bool
    }

    /// 從含 ANSI 的畫面找出建議文字;沒有建議回 `nil`。
    public static func detect(screen: String) -> String? {
        let lines = screen.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map(cells)
        guard let index = lines.lastIndex(where: { $0.map { visible($0).hasPrefix(inputPrefix) } ?? false }),
              let bottom = lines[(index + 1)...].firstIndex(where: { $0.map(isSeparator) ?? false }) else { return nil }
        var parts: [String] = []
        for (offset, line) in lines[index..<bottom].enumerated() {
            guard var cells = line else { return nil }
            if offset == 0 { cells.removeFirst(inputPrefix.count) }
            guard cells.allSatisfy({ $0.character.isWhitespace || $0.dim }) else { return nil }
            let text = visible(cells).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { parts.append(text) }
        }
        let text = parts.joined(separator: " ")
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

    private static func visible(_ cells: [Cell]) -> String {
        String(cells.map(\.character))
    }

    /// 輸入框的上下緣：整行(去掉兩端空白)只有 `─`。
    private static func isSeparator(_ cells: [Cell]) -> Bool {
        let text = visible(cells).trimmingCharacters(in: .whitespaces)
        return !text.isEmpty && text.allSatisfy { $0 == "─" }
    }

    /// 一行的可見字元與 dim 狀態(每行從非 dim 開始);有認不得的跳脫序列回 `nil`。
    static func cells(_ line: String) -> [Cell]? {
        var cells: [Cell] = []
        var dim = false
        var rest = Substring(line)
        while let first = rest.first {
            guard first == "\u{1B}" else {
                cells.append(Cell(character: first, dim: dim))
                rest = rest.dropFirst()
                continue
            }
            guard let (parameters, remainder) = escape(rest) else { return nil }
            rest = remainder
            if let parameters { dim = applySGR(parameters, dim: dim) }
        }
        return cells
    }

    /// 一個跳脫序列：SGR(`ESC [ … m`)回傳參數，其他(CSI、OSC、單字元跳脫)回傳 `nil` 參數;不完整時整個回 `nil`。
    private static func escape(_ text: Substring) -> (String?, Substring)? {
        var rest = text.dropFirst()
        guard let introducer = rest.first else { return nil }
        rest = rest.dropFirst()
        switch introducer {
        case "[":
            var body = ""
            while let character = rest.first {
                rest = rest.dropFirst()
                guard let scalar = character.unicodeScalars.first?.value else { return nil }
                if (0x40...0x7E).contains(scalar) {
                    return (character == "m" ? body : nil, rest)
                }
                body.append(character)
            }
            return nil
        case "]":
            // OSC(例如 OSC 8 超連結):到 BEL 或 ST(`ESC \`)為止。
            while let character = rest.first {
                rest = rest.dropFirst()
                if character == "\u{07}" { return (nil, rest) }
                if character == "\u{1B}", rest.first == "\\" { return (nil, rest.dropFirst()) }
            }
            return nil
        default:
            return (nil, rest)
        }
    }

    /// 套用 SGR 參數，只追蹤 dim:`0`／空 重設、`2` 開、`22` 關。
    /// - `38`／`48`／`58` 的分號延伸色(`;5;n`、`;2;r;g;b`)跳過後面的參數。
    /// - 冒號子參數(`4:3`、`38:2::r:g:b`)整組是一個屬性，只看第一段，不吃掉後面的參數。
    /// - `<=>?` 開頭(私有，不是 SGR)與不是整數的參數忽略，不當成重設。
    private static func applySGR(_ parameters: String, dim: Bool) -> Bool {
        if let first = parameters.first, "<=>?".contains(first) { return dim }
        var dim = dim
        let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            let isCompound = field.contains(":")
            let head = isCompound ? field.prefix { $0 != ":" } : field
            guard let code = head.isEmpty ? 0 : Int(head) else { continue }
            switch code {
            case 0: dim = false
            case 2: dim = true
            case 22: dim = false
            case 38, 48, 58:
                guard !isCompound, index < fields.count else { break }
                switch fields[index] {
                case "5": index += 2
                case "2": index += 4
                default: break
                }
            default: break
            }
        }
        return dim
    }
}
