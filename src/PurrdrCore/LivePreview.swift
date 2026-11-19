import Foundation

/// 即時預覽(行為規格 F5.11、§4.8、R-Q11):從 working 的 pane 可見畫面(`pane.read` visible)擷取 agent 正在寫的散文。
///
/// 錯的預覽會被當成 agent 的回答，所以只有找到真正的散文才回傳;工具輸出、使用者的 prompt、不到 20 字都回 `nil`。
public enum LivePreview {
    /// 最少字數(錯的預覽比沒有更糟)。
    static let minimumLength = 20
    /// 從錨點往上最多收幾行。
    static let maximumLines = 8

    public static func extract(screen: String) -> String? {
        var lines = screen.components(separatedBy: "\n").map(clean)
        lines = dropBottomChrome(lines)
        let anchor = anchorIndex(in: lines)
        if isCodexToolTurn(lines[..<anchor]) { return nil }

        var collected: [String] = []
        var index = anchor - 1
        while index >= 0, collected.count < maximumLines {
            let line = lines[index]
            index -= 1
            if line.isEmpty {
                if collected.isEmpty { continue }
                break
            }
            if let first = line.first, first == "❯" || first == "›", line.dropFirst().contains(where: { !$0.isWhitespace }) {
                // 使用者打的 prompt:散文到此為止。
                break
            }
            if line.hasPrefix("⎿") { return nil }
            if isChrome(line) { continue }
            collected.append(line)
        }
        guard !collected.isEmpty else { return nil }
        var text = collected.reversed().joined(separator: " ")
        // 規格只列 ⏺ ● ⏵;Codex 的散文以「• 」開頭，一併去掉(決定，見 #44 筆記)。
        for marker in ["⏺", "●", "⏵", "•"] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return text.count >= minimumLength ? text : nil
    }

    /// 預覽是否已是 `reply` 的一部分(#208)。畫面會換行、全形標點可能變半形，所以忽略空白、相容字元與 markdown 記號比對。
    public static func isWritten(_ preview: String, in reply: String) -> Bool {
        let needle = comparable(preview)
        return !needle.isEmpty && comparable(reply).contains(needle)
    }

    private static let ignoredInComparison = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`#>~|"))

    private static func comparable(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !ignoredInComparison.contains($0) }
        ))
    }

    // MARK: - 清理

    private static let borders = CharacterSet(charactersIn: "│┃|╭╮╰╯─┌┐└┘├┤ \t")

    /// 去 OSC、CSI 與其他跳脫序列(正規式真的含 ESC 字元,#12);只修剪兩端框線，內部 `│┃` 換成 `|`。
    static func clean(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "\r", with: "")
        line = ANSIText.strip(line)
        line = line.trimmingCharacters(in: borders)
        return line.replacingOccurrences(of: "│", with: "|").replacingOccurrences(of: "┃", with: "|")
    }

    /// Codex 的「Queued follow-up inputs」面板到結尾、含「← for agents」的輸入框頁尾以下全部不要。
    private static func dropBottomChrome(_ lines: [String]) -> [String] {
        if let queued = lines.firstIndex(where: { $0.contains("Queued follow-up inputs") }) {
            return Array(lines[..<queued])
        }
        if let footer = lines.lastIndex(where: { $0.contains("← for agents") }) {
            // 頁尾屬於輸入框：從輸入框上緣(往上最近的分隔線)起都不要。
            let top = lines[..<footer].lastIndex(where: isSeparator) ?? footer
            return Array(lines[..<top])
        }
        return lines
    }

    // MARK: - 錨點

    /// 依序找最後一個：spinner 行、狀態行、不含 `…` 的類 spinner 行、以 `❯`/`›` 開頭的輸入框;都沒有時是畫面結尾。
    private static func anchorIndex(in lines: [String]) -> Int {
        if let spinner = lines.lastIndex(where: { isSpinnerLike($0) && $0.contains("…") }) { return spinner }
        if let status = lines.lastIndex(where: isStatusLine) { return status }
        if let spinner = lines.lastIndex(where: isSpinnerLike) { return spinner }
        if let input = lines.lastIndex(where: { $0.hasPrefix("❯") || $0.hasPrefix("›") }) { return input }
        return lines.count
    }

    private static let spinnerMarks = Set("✳✽✻✢✶✷✸✹✺⚹∗·")

    /// 首字是 spinner 記號(或 U+2801–U+28FF 點字),接空白與字母。
    static func isSpinnerLike(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 3, let first = line.first else { return false }
        let isMark = spinnerMarks.contains(first) || (0x2801...0x28FF).contains(scalars[0].value)
        guard isMark else { return false }
        let rest = line.dropFirst()
        guard let space = rest.first, space.isWhitespace else { return false }
        return rest.drop { $0.isWhitespace }.first?.isLetter == true
    }

    private static func isStatusLine(_ line: String) -> Bool {
        guard !isAgentsPaneLine(line), !line.contains("for agents") else { return false }
        return line.contains("esc to interrupt") || line.contains("tokens)") || line.contains("token · ")
            || (line.contains("↓ ") && line.contains("token"))
    }

    /// Codex:錨點前最後一個 `• ` 行是工具(Ran、Running、Viewed Image、Explored、Searched)→ 這一輪在跑工具，不是在寫散文。
    private static func isCodexToolTurn(_ lines: ArraySlice<String>) -> Bool {
        guard let bullet = lines.last(where: { $0.hasPrefix("• ") }) else { return false }
        let body = bullet.dropFirst(2)
        return ["Ran", "Running", "Viewed Image", "Explored", "Searched"].contains { body.hasPrefix($0) }
    }

    // MARK: - chrome

    /// 介面的符號標記，出現在哪裡都算。
    private static let chromeMarks = ["◉", "⏸"]
    /// 介面列的關鍵字(小寫比對):只在行首或 `·` 分隔的狀態列裡才算，散文提到不算(#214)。
    private static let chromePhrases = [
        "manual mode", "for agents", "/effort", "esc to", "ctrl+", "resume this session", "? for shortcuts",
        "restart to update", "auto-update", "ctx:",
    ]

    private static func isChrome(_ line: String) -> Bool {
        if let first = line.first, "❯›>".contains(first) { return true }
        if isAgentsPaneLine(line) || isSpinnerLike(line) || isSeparator(line) { return true }
        if line.unicodeScalars.allSatisfy({ (0x2800...0x28FF).contains($0.value) || (0x2580...0x259F).contains($0.value) || $0 == " " }) {
            return true
        }
        if chromeMarks.contains(where: line.contains) { return true }
        if isChromePhraseLine(line.lowercased()) { return true }
        return line.contains("@") && line.filter { $0 == "|" }.count >= 3
    }

    /// 以關鍵字開頭(前導的 ✔ ⏵ 等記號不算),或是含關鍵字、以 ` · ` 分隔的狀態列。
    private static func isChromePhraseLine(_ lowercased: String) -> Bool {
        let body = lowercased.drop { !$0.isLetter && !$0.isNumber && !"?/".contains($0) }
        if chromePhrases.contains(where: body.hasPrefix) { return true }
        return lowercased.contains(" · ") && chromePhrases.contains(where: lowercased.contains)
    }

    private static func isSeparator(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { "-─=".contains($0) }
    }

    /// Claude 背景 agents 窗格的標頭與列(§4.8)。
    private static func isAgentsPaneLine(_ line: String) -> Bool {
        if line.hasPrefix("⏺ main") || line.hasPrefix("● main") { return true }
        guard let first = line.first else { return false }
        return "◯○".contains(first) || (line.hasPrefix("↓ ") && line.hasSuffix("more"))
    }
}
