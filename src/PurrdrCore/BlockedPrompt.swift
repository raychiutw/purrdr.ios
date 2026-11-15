import Foundation

/// Agent 停下來等使用者回答的提示(UI 稱「需要你」;行為規格 F8、§5)。從 pane 的 visible 畫面解析。
public struct BlockedPrompt: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 編號選單(權限、AskUserQuestion、Codex 的信任…)。
        case menu
        /// 沒有編號的資料夾信任提示：每個選項帶自己的方向鍵(§5.4)。
        case trust
        /// Codex 的 `@` 檔案選擇器：只能關閉(§5.1)。
        case filePicker
        /// 畫面上看不出選單：只給通用鈕。
        case unrecognized
    }

    public var kind: Kind
    /// 問題文字;沒解析到為 `nil`(畫面顯示「agent 在等」)。
    public var question: String?
    /// 要批准的是什麼(§5.3)。
    public var details: PromptDetails?
    /// 提示的開頭已捲出讀取範圍：細節不完整，請看終端機。
    public var detailsOffscreen: Bool
    public var options: [PromptOption]

    public init(kind: Kind, question: String?, details: PromptDetails? = nil, detailsOffscreen: Bool = false, options: [PromptOption] = []) {
        self.kind = kind
        self.question = question
        self.details = details
        self.detailsOffscreen = detailsOffscreen
        self.options = options
    }

    /// 沒解析到選單時的提示。
    public static let unrecognized = BlockedPrompt(kind: .unrecognized, question: nil)

    /// 有勾選列 = 多選。
    public var isMultiSelect: Bool { options.contains { $0.checked != nil } }

    /// 判斷「同一個提示」用(§5.5):問題 + 細節的標題、摘要、內容(不含附註：期限每秒在變)+ 每個選項的編號、勾選與標籤。
    public var signature: String {
        var parts = [String(describing: kind), question ?? ""]
        parts += [details?.title ?? "", details?.summary ?? ""] + (details?.content ?? [])
        parts += options.map { option in
            let box = option.checked.map { $0 ? "[x]" : "[ ]" } ?? ""
            return "\(option.number.map(String.init) ?? "-").\(box)\(option.label)"
        }
        return parts.joined(separator: "\u{1F}")
    }
}

/// 權限提示的細節(§5.3)。
public struct PromptDetails: Sendable, Equatable {
    /// `Bash command`、`Edit file`…;AskUserQuestion 的分頁頭不算標題。
    public var title: String?
    public var summary: String?
    /// 指令或 diff(等寬顯示，不換行)。
    public var content: [String]
    /// 附註(注意色),例如「X 後自動拒絕」——直接用畫面上的字，不在手機倒數。
    public var note: String?

    public init(title: String?, summary: String? = nil, content: [String] = [], note: String? = nil) {
        self.title = title
        self.summary = summary
        self.content = content
        self.note = note
    }

    var isEmpty: Bool { title == nil && summary == nil && content.isEmpty && note == nil }
}

/// 從 pane 畫面解析提示(§5.2–§5.4)。
public enum BlockedPromptParser {
    /// 解析畫面上的提示;看不出任何選單時回 `nil`。
    public static func parse(screen: String, agentKind: String) -> BlockedPrompt? {
        let lines = ClaudeTranscriptParser.stripANSI(screen)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "    ") }
            .map { $0.trimmingTrailingWhitespace() }
        if agentKind == "codex", isCodexFilePicker(lines) {
            return BlockedPrompt(kind: .filePicker, question: "Codex has its file picker open.")
        }
        if let trust = trustPrompt(lines) { return trust }
        guard let menu = lastMenu(in: lines) else { return nil }
        var question = questionLines(above: menu.firstLine, in: lines)
        var details: PromptDetails?
        var offscreen = false
        switch locateDetails(above: question?.start ?? menu.firstLine, in: lines) {
        case .block(let range):
            details = parseBlock(Array(lines[range]))
        case .offscreen:
            offscreen = true
        case .conversation(let stop):
            if let codex = codexDetails(question: question, from: stop, in: lines) {
                details = codex.details
                question = (codex.question, question?.start ?? menu.firstLine)
            }
        case .none:
            break
        }
        return BlockedPrompt(
            kind: .menu, question: question?.text, details: details?.isEmpty == false ? details : nil,
            detailsOffscreen: offscreen, options: menu.options
        )
    }

    // MARK: - 選單(§5.2)

    private struct Menu {
        var options: [PromptOption] = []
        /// 編號所在的欄(縮排超過它的行屬於上一個選項)。
        var numberColumn = 0
        var firstLine = 0
        var hasCursor = false
    }

    private struct OptionLine {
        var number: Int
        var label: String
        var checked: Bool?
        var isCursor: Bool
        var column: Int
    }

    private static let cursorCharacters: Set<Character> = ["❯", "›", "▶", ">", "→", "•", "*"]

    /// 最後一個連續選單(編號不大於前一個時重置)。至少要有一列帶游標，否則只是對話中的編號清單。
    private static func lastMenu(in lines: [String]) -> Menu? {
        var result: Menu?
        var current: Menu?
        var pendingWrap: [String] = []

        func close() {
            if let menu = current, menu.hasCursor, !menu.options.isEmpty { result = menu }
            current = nil
            pendingWrap = []
        }

        for (index, line) in lines.enumerated() {
            if let menu = current, line.leadingSpaces > menu.numberColumn, !line.isBlank {
                // 縮排超過編號欄：上一個選項的描述、折行或預覽，永不是新選項(#107)。
                continue
            }
            if let option = optionLine(line) {
                if var menu = current, let last = menu.options.last?.number, option.number > last {
                    if !pendingWrap.isEmpty, let lastIndex = menu.options.indices.last {
                        menu.options[lastIndex].label += " " + pendingWrap.joined(separator: " ")
                    }
                    pendingWrap = []
                    menu.options.append(PromptOption(number: option.number, label: option.label, checked: option.checked, isCursor: option.isCursor))
                    menu.hasCursor = menu.hasCursor || option.isCursor
                    current = menu
                } else {
                    close()
                    current = Menu(
                        options: [PromptOption(number: option.number, label: option.label, checked: option.checked, isCursor: option.isCursor)],
                        numberColumn: option.column, firstLine: index, hasCursor: option.isCursor
                    )
                }
                continue
            }
            guard current != nil else { continue }
            if line.isBlank || isSeparator(line) {
                close()
            } else {
                // 兩個選項之間、沒縮排的非選項行：接續上面的標籤(agy 會折到第 0 欄)。
                pendingWrap.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        close()
        return result
    }

    private static func optionLine(_ line: String) -> OptionLine? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " " { index += 1 }
        var isCursor = false
        if index < characters.count, cursorCharacters.contains(characters[index]) {
            isCursor = true
            index += 1
            while index < characters.count, characters[index] == " " { index += 1 }
        }
        let column = index
        let rest = String(characters[index...])
        // Grok:`2 (○) Yes, proceed`;字母列(`z (○) …`)不是選項。
        if let grok = rest.wholeMatch(of: /([1-9]) \([●○]\) (.+)/) {
            return OptionLine(number: Int(grok.output.1) ?? 0, label: cleanLabel(String(grok.output.2)), checked: nil, isCursor: isCursor, column: column)
        }
        guard let match = rest.wholeMatch(of: /(\d{1,2})[.)]\s+(.+)/), let number = Int(match.output.1) else { return nil }
        var label = String(match.output.2)
        var checked: Bool?
        if let box = label.prefixMatch(of: /\[([ xX✔✓])\]\s*/) {
            checked = box.output.1 != " "
            label = String(label[box.range.upperBound...])
        }
        label = cleanLabel(label)
        guard !label.isEmpty else { return nil }
        return OptionLine(number: number, label: label, checked: checked, isCursor: isCursor, column: column)
    }

    /// 截掉側邊預覽面板，去掉結尾的快捷鍵提示。
    private static func cleanLabel(_ raw: String) -> String {
        var label = raw
        if let panel = label.firstMatch(of: /\s{2,}[│┃┌└├╭╰]/) { label = String(label[..<panel.range.lowerBound]) }
        label = label.trimmingCharacters(in: .whitespaces)
        if let hint = label.firstMatch(of: /\s*\((?:[a-z]|esc|enter|return|tab|shift\+tab)\)$/) {
            label = String(label[..<hint.range.lowerBound])
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 問題

    /// 第一個選項正上方的連續行(先跳過空行),往上到空行、選項或分隔線，以空白連接。
    private static func questionLines(above first: Int, in lines: [String]) -> (text: String, start: Int)? {
        var index = first - 1
        while index >= 0, lines[index].isBlank { index -= 1 }
        var collected: [String] = []
        var start = first
        while index >= 0, !lines[index].isBlank, !isSeparator(lines[index]), !isDashed(lines[index]), optionLine(lines[index]) == nil {
            collected.insert(lines[index].trimmingCharacters(in: .whitespaces), at: 0)
            start = index
            index -= 1
        }
        guard !collected.isEmpty else { return nil }
        return (collected.joined(separator: " "), start)
    }

    // MARK: - 細節(§5.3)

    private enum DetailsLocation {
        /// 開頭分隔線之後到問題之前。
        case block(Range<Int>)
        /// 越過邊界後到了畫面頂端：提示開頭在畫面外。
        case offscreen
        /// 先遇到對話記號(Codex 沒有分隔線):從這一行之後找 Codex 形式。
        case conversation(Int)
        case none
    }

    private static let conversationMarks: Set<Character> = ["⏺", "⎿", "❯", "›", "•", "✻", "✳", "✢", "✶", "✽", ">"]

    private static func locateDetails(above questionStart: Int, in lines: [String]) -> DetailsLocation {
        var crossedBoundary = false
        var index = questionStart - 1
        while index >= 0 {
            let line = lines[index]
            if isSeparator(line) { return .block((index + 1)..<questionStart) }
            if line.leadingSpaces <= 2, let first = line.trimmingCharacters(in: .whitespaces).first, conversationMarks.contains(first) {
                return .conversation(index)
            }
            if isDashed(line) || line.trimmingCharacters(in: .whitespaces).hasPrefix("│ ") { crossedBoundary = true }
            index -= 1
        }
        return crossedBoundary ? .offscreen : .conversation(-1)
    }

    private static func parseBlock(_ raw: [String]) -> PromptDetails {
        var lines = raw
        while lines.first?.isBlank == true { lines.removeFirst() }
        while lines.last?.isBlank == true { lines.removeLast() }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Tip:") }
        guard let first = lines.first else { return PromptDetails(title: nil) }
        var title: String? = first.trimmingCharacters(in: .whitespaces)
        if let character = title?.first, "←→☐☒☑✔✓□■●◯".contains(character) { title = nil }
        lines.removeFirst()
        // 標題下緊接的行(到空行或分隔)是摘要。
        var summary: [String] = []
        while let line = lines.first, !line.isBlank, !isDashed(line) {
            summary.append(line.trimmingCharacters(in: .whitespaces))
            lines.removeFirst()
        }
        var content: [String] = []
        var note: [String] = []
        let dashes = lines.indices.filter { isDashed(lines[$0]) }
        if dashes.count >= 2, let open = dashes.first, let close = dashes.last {
            content = Array(lines[(open + 1)..<close])
            note = lines[(close + 1)...].filter { !$0.isBlank }.map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            for line in lines where !line.isBlank && !isDashed(line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("⚠") || trimmed.contains("automatically deny") {
                    note.append(trimmed)
                } else {
                    content.append(line)
                }
            }
        }
        return PromptDetails(
            title: title, summary: summary.isEmpty ? nil : summary.joined(separator: " "),
            content: dedent(content), note: note.isEmpty ? nil : note.joined(separator: " ")
        )
    }

    /// Codex:沒有分隔線;問題上方的段落以 `Would you like to …` 開頭。標題以 `the following command?` 結尾、
    /// 問題以 `$ ` 開頭時，指令是內容、其間的散文(Reason、Environment)是摘要。
    private static func codexDetails(question: (text: String, start: Int)?, from stop: Int, in lines: [String]) -> (question: String, details: PromptDetails)? {
        guard let question else { return nil }
        let range = (stop + 1)..<question.start
        guard !range.isEmpty, let titleIndex = range.first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("Would you like to") }) else {
            return nil
        }
        let title = lines[titleIndex].trimmingCharacters(in: .whitespaces)
        let prose = lines[(titleIndex + 1)..<question.start].filter { !$0.isBlank }.map { $0.trimmingCharacters(in: .whitespaces) }
        if title.hasSuffix("the following command?"), question.text.hasPrefix("$ ") {
            return (title, PromptDetails(title: nil, summary: prose.isEmpty ? nil : prose.joined(separator: " "), content: [question.text]))
        }
        return (question.text, PromptDetails(title: title, summary: prose.isEmpty ? nil : prose.joined(separator: " ")))
    }

    // MARK: - 資料夾信任(§5.4)

    private static func trustPrompt(_ lines: [String]) -> BlockedPrompt? {
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Accessing workspace:" }),
              let yes = lines.lastIndex(where: { trustLabel($0) == "Yes, I trust this folder" }) else { return nil }
        var start = yes
        while start > 0, !lines[start - 1].isBlank { start -= 1 }
        var end = yes
        while end + 1 < lines.count, !lines[end + 1].isBlank { end += 1 }
        let rows = Array(start...end)
        guard let cursor = rows.first(where: { isTrustCursor(lines[$0]) }) else { return nil }
        let options = rows.compactMap { row -> PromptOption? in
            let label = trustLabel(lines[row])
            guard label == "Yes, I trust this folder" || label.hasPrefix("No") else { return nil }
            let distance = row - cursor
            let moves = Array(repeating: distance > 0 ? "down" : "up", count: abs(distance))
            return PromptOption(number: nil, label: label, keys: moves + ["enter"], isCursor: row == cursor)
        }
        // 資料夾：標頭下第一段，折行接回不加空白。
        var index = header + 1
        while index < lines.count, lines[index].isBlank { index += 1 }
        var folder = ""
        while index < lines.count, !lines[index].isBlank {
            folder += lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
        }
        let agent = lines.lazy.compactMap { line -> String? in
            guard let range = line.range(of: " requires permission to") else { return nil }
            let name = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }.first ?? "Claude Code"
        let question = folder.hasPrefix("/") || folder.hasPrefix("~")
            ? "Trust \(folder)? \(agent) will be able to read, edit, and run files there."
            : "Trust this folder?"
        return BlockedPrompt(kind: .trust, question: question, options: options)
    }

    private static func isTrustCursor(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("❯") || trimmed.hasPrefix(">")
    }

    private static func trustLabel(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if isTrustCursor(trimmed) { trimmed.removeFirst() }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 其他

    private static func isCodexFilePicker(_ lines: [String]) -> Bool {
        let screen = lines.joined(separator: "\n")
        return screen.contains("All Results") && screen.contains("Filesystem Only") && screen.contains("Plugins")
    }

    /// 實心分隔線(8 個以上 `─━▔`)或框頂 `╭──…╮`。
    static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 8, trimmed.allSatisfy({ "─━▔".contains($0) }) { return true }
        return trimmed.hasPrefix("╭──") && trimmed.hasSuffix("╮")
    }

    /// 虛線分隔(8 個以上 `╌╍┄┅┈┉`)。
    static func isDashed(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 8 && trimmed.allSatisfy { "╌╍┄┅┈┉".contains($0) }
    }

    /// 去掉共同縮排與指令的 `│ ` 邊界。
    private static func dedent(_ lines: [String]) -> [String] {
        let unbordered = lines.map { line -> String in
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("│ ") else { return line }
            return String(trimmed.dropFirst(2))
        }
        let indent = unbordered.filter { !$0.isBlank }.map(\.leadingSpaces).min() ?? 0
        return unbordered.map { String($0.dropFirst(min(indent, $0.leadingSpaces))) }
    }
}

private extension String {
    var leadingSpaces: Int { prefix { $0 == " " }.count }

    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last == " " { result.removeLast() }
        return result
    }
}
