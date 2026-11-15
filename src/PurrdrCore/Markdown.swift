import Foundation

/// agent 文字的 markdown 區塊(行為規格 F5.10)。不認得的當段落。
public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    /// 清單。編號清單保留起始號。
    case list(ordered: Bool, start: Int, items: [[MarkdownInline]])
    case quote([MarkdownBlock])
    case rule
    /// 圍欄程式碼。`text` 不含結尾換行。
    case code(language: String?, text: String)
    case table(MarkdownTable)
}

/// 行內元素。連結只會是 http(s) 且有主機的網址(R-V03);其他 scheme 與相對路徑只留文字。
public indirect enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case code(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case link(text: [MarkdownInline], url: String)
}

/// GFM 表格。每一列的格數與標題相同(短列補齊、多的格併回最後一格)。
public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case leading, center, trailing }

    public var alignments: [Alignment]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]]

    public init(alignments: [Alignment], header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

/// 解析 agent 文字的 markdown(行為規格 F5.10)。只涵蓋 agent 常寫的子集，不是完整的 CommonMark。
public enum Markdown {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var parser = BlockParser(lines: lines)
        return parser.parse()
    }

    public static func inlines(_ text: String) -> [MarkdownInline] {
        InlineParser(Array(text)).parse()
    }

    /// 只有 http/https 且有主機的網址可點(R-V03)。
    public static func isWebURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return false }
        return true
    }
}

// MARK: - 區塊

private struct BlockParser {
    let lines: [String]
    var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func parse() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            if line.isBlank {
                index += 1
            } else if let fence = Self.fence(line) {
                blocks.append(code(fence))
            } else if let heading = Self.heading(line) {
                blocks.append(heading)
                index += 1
            } else if Self.isRule(line) {
                blocks.append(.rule)
                index += 1
            } else if isTableStart(index) {
                blocks.append(table())
            } else if Self.quoteContent(line) != nil {
                blocks.append(quote())
            } else if let marker = Self.listMarker(line) {
                blocks.append(list(ordered: marker.ordered, start: marker.number))
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks
    }

    // 圍欄：3 個以上反引號或波浪號。只有同字元、長度 ≥ 開頭、且該行沒有其他內容的才關閉(#108)。
    static func fence(_ line: String) -> (character: Character, length: Int, info: String)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        return (first, length, info)
    }

    mutating func code(_ fence: (character: Character, length: Int, info: String)) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.count >= fence.length, trimmed.allSatisfy({ $0 == fence.character }) { break }
            body.append(lines[index - 1])
        }
        let language = fence.info.split(separator: " ").first.map(String.init)
        return .code(language: language, text: body.joined(separator: "\n"))
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        guard let match = line.wholeMatch(of: /\s{0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*/) else { return nil }
        return .heading(level: match.output.1.count, Markdown.inlines(String(match.output.2 ?? "")))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func quoteContent(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == ">" else { return nil }
        let rest = trimmed.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    static func listMarker(_ line: String) -> (ordered: Bool, number: Int, content: String)? {
        if let match = line.wholeMatch(of: /\s{0,3}(\d{1,9})[.)]\s+(.*)/) {
            return (true, Int(match.output.1) ?? 1, String(match.output.2))
        }
        if let match = line.wholeMatch(of: /\s{0,3}[-*+]\s+(.*)/) {
            return (false, 1, String(match.output.1))
        }
        return nil
    }

    func startsBlock(_ line: String) -> Bool {
        Self.fence(line) != nil || Self.heading(line) != nil || Self.isRule(line) || Self.quoteContent(line) != nil
            || Self.listMarker(line) != nil
    }

    mutating func quote() -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count, let content = Self.quoteContent(lines[index]) {
            inner.append(content)
            index += 1
        }
        var parser = BlockParser(lines: inner)
        return .quote(parser.parse())
    }

    mutating func list(ordered: Bool, start: Int) -> MarkdownBlock {
        var items: [String] = []
        while index < lines.count {
            let line = lines[index]
            if let marker = Self.listMarker(line), marker.ordered == ordered {
                items.append(marker.content)
                index += 1
            } else if !line.isBlank, line.first == " " || line.first == "\t", !items.isEmpty, Self.listMarker(line) == nil {
                // 縮排的續行併進上一項。
                items[items.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        return .list(ordered: ordered, start: start, items: items.map(Markdown.inlines))
    }

    mutating func paragraph() -> MarkdownBlock {
        var body: [String] = [lines[index].trimmingCharacters(in: .whitespaces)]
        index += 1
        while index < lines.count, !lines[index].isBlank, !startsBlock(lines[index]), !isTableStart(index) {
            body.append(lines[index].trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .paragraph(Markdown.inlines(body.joined(separator: "\n")))
    }

    // MARK: 表格

    func isTableStart(_ index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        return Self.alignments(lines[index + 1]) != nil
    }

    static func alignments(_ line: String) -> [MarkdownTable.Alignment]? {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            guard cell.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    mutating func table() -> MarkdownBlock {
        let header = Self.splitRow(lines[index])
        let alignments = Self.alignments(lines[index + 1]) ?? []
        let width = header.count
        index += 2
        var rows: [[[MarkdownInline]]] = []
        while index < lines.count, !lines[index].isBlank, lines[index].contains("|") {
            var cells = Self.splitRow(lines[index])
            if cells.count > width, width > 0 {
                // 多的格併回最後一格。
                let merged = cells[(width - 1)...].joined(separator: " | ")
                cells = Array(cells.prefix(width - 1)) + [merged]
            }
            while cells.count < width { cells.append("") }
            rows.append(cells.map(Markdown.inlines))
            index += 1
        }
        let aligned = (0..<width).map { $0 < alignments.count ? alignments[$0] : .leading }
        return .table(MarkdownTable(alignments: aligned, header: header.map(Markdown.inlines), rows: rows))
    }

    /// 以 `|` 分格：`\|` 是字面，程式碼內的 `|` 不分格;頭尾的 `|` 去掉。
    static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var characters = Array(line.trimmingCharacters(in: .whitespaces))
        if characters.first == "|" { characters.removeFirst() }
        if characters.last == "|", characters.dropLast().last != "\\" { characters.removeLast() }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - 行內

private struct InlineParser {
    let characters: [Character]

    init(_ characters: [Character]) {
        self.characters = characters
    }

    func parse() -> [MarkdownInline] {
        parse(0, characters.count)
    }

    private func parse(_ start: Int, _ end: Int) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var text = ""
        func flush() {
            if !text.isEmpty { result.append(.text(text)) }
            text = ""
        }
        var index = start
        while index < end {
            let character = characters[index]
            if character == "\\", index + 1 < end, characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                text.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`", let (code, next) = codeSpan(at: index, end: end) {
                flush()
                result.append(.code(code))
                index = next
                continue
            }
            if character == "[", let (label, url, next) = link(at: index, end: end) {
                flush()
                let inner = parse(label.lowerBound, label.upperBound)
                if Markdown.isWebURL(url) {
                    result.append(.link(text: inner, url: url))
                } else {
                    // 其他 scheme 與相對路徑只留文字。
                    result += inner
                }
                index = next
                continue
            }
            if character == "<", let close = (index + 1..<end).first(where: { characters[$0] == ">" }) {
                let inner = String(characters[(index + 1)..<close])
                if Markdown.isWebURL(inner) {
                    flush()
                    result.append(.link(text: [.text(inner)], url: inner))
                    index = close + 1
                    continue
                }
            }
            if character == "h", index == start || !characters[index - 1].isLetterOrNumber, let (url, next) = bareURL(at: index, end: end) {
                flush()
                result.append(.link(text: [.text(url)], url: url))
                index = next
                continue
            }
            if character == "*" || character == "_", let (inner, run, next) = emphasis(at: index, end: end) {
                flush()
                let children = parse(inner.lowerBound, inner.upperBound)
                result.append(run == 2 ? .strong(children) : .emphasis(children))
                index = next
                continue
            }
            text.append(character)
            index += 1
        }
        flush()
        return merged(result)
    }

    private func merged(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let next) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(inline)
            }
        }
        return result
    }

    private func run(of character: Character, at index: Int, end: Int) -> Int {
        var count = 0
        while index + count < end, characters[index + count] == character { count += 1 }
        return count
    }

    private func codeSpan(at index: Int, end: Int) -> (String, Int)? {
        let length = run(of: "`", at: index, end: end)
        var search = index + length
        while search < end {
            if characters[search] == "`" {
                let closing = run(of: "`", at: search, end: end)
                if closing == length {
                    var content = String(characters[(index + length)..<search])
                    if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    return (content, search + closing)
                }
                search += closing
            } else {
                search += 1
            }
        }
        return nil
    }

    /// `[文字](網址)`;網址可含一層成對括號。
    private func link(at index: Int, end: Int) -> (Range<Int>, String, Int)? {
        var depth = 0
        var close: Int?
        var search = index
        while search < end {
            switch characters[search] {
            case "\\": search += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { close = search }
            default: break
            }
            if close != nil { break }
            search += 1
        }
        guard let close, close + 1 < end, characters[close + 1] == "(" else { return nil }
        var parens = 0
        var cursor = close + 2
        while cursor < end {
            let character = characters[cursor]
            if character == "(" { parens += 1 }
            if character == ")" {
                if parens == 0 { break }
                parens -= 1
            }
            cursor += 1
        }
        guard cursor < end else { return nil }
        let url = String(characters[(close + 2)..<cursor]).trimmingCharacters(in: .whitespaces)
        return ((index + 1)..<close, url, cursor + 1)
    }

    /// 裸 `http(s)://`:到空白或 `<` 為止;結尾標點與不成對的 `)` 不算。
    private func bareURL(at index: Int, end: Int) -> (String, Int)? {
        let rest = String(characters[index..<min(end, index + 8)])
        guard rest.hasPrefix("https://") || rest.hasPrefix("http://") else { return nil }
        var stop = index
        while stop < end, !characters[stop].isWhitespace, characters[stop] != "<" { stop += 1 }
        var candidate = Array(characters[index..<stop])
        while let last = candidate.last {
            if ".,;:!?'\"*_".contains(last) {
                candidate.removeLast()
            } else if last == ")", candidate.filter({ $0 == "(" }).count < candidate.filter({ $0 == ")" }).count {
                candidate.removeLast()
            } else {
                break
            }
        }
        let url = String(candidate)
        guard Markdown.isWebURL(url) else { return nil }
        return (url, index + candidate.count)
    }

    /// `*x*`、`_x_`(斜體)與 `**x**`、`__x__`(粗體)。`_` 在識別字中是字面。
    private func emphasis(at index: Int, end: Int) -> (Range<Int>, Int, Int)? {
        let delimiter = characters[index]
        let available = run(of: delimiter, at: index, end: end)
        let length = min(available, 2)
        let open = index + length
        guard open < end, !characters[open].isWhitespace else { return nil }
        if delimiter == "_", index > 0, characters[index - 1].isLetterOrNumber { return nil }
        var search = open
        while search < end {
            if characters[search] == "`", let (_, next) = codeSpan(at: search, end: end) {
                search = next
                continue
            }
            if characters[search] == delimiter, run(of: delimiter, at: search, end: end) >= length, search > open,
               !characters[search - 1].isWhitespace {
                let after = search + length
                if delimiter == "_", after < end, characters[after].isLetterOrNumber {
                    search += 1
                    continue
                }
                return (open..<search, length, after)
            }
            search += 1
        }
        return nil
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
