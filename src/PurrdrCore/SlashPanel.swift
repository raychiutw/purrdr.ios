import Foundation

/// slash 指令在終端機開出的面板(`/model`、`/effort`…;#45、行為規格 F9.4、§5.6)。從 pane 的 visible 畫面解析。
///
/// 面板開著時 herdr 回報的狀態仍是 idle(面板對 herdr 不可見),所以由對話在送出 slash 指令後主動讀畫面。
/// 操作一律送游標鍵與面板自己的動作鍵，**永不送數字**:數字在模型選擇器會直接選定並存成預設(R-C04)。
public struct SlashPanel: Sendable, Equatable {
    public var title: String?
    /// 標題下的說明(每行一個)。
    public var notes: [String]
    public var options: [SlashPanelOption]
    /// 層級滑桿(effort)。
    public var slider: SlashPanelSlider?
    /// 可用 ←/→ 調整時為那一行的文字(例如 `◐ Medium effort`;寫在提示行時是空字串);不能調整為 `nil`。
    public var adjustment: String?
    /// 面板自己的動作(取自提示行，例如設為預設、只用於此 session、取消)。
    public var actions: [SlashPanelAction]

    public init(title: String?, notes: [String] = [], options: [SlashPanelOption] = [], slider: SlashPanelSlider? = nil,
                adjustment: String? = nil, actions: [SlashPanelAction] = []) {
        self.title = title
        self.notes = notes
        self.options = options
        self.slider = slider
        self.adjustment = adjustment
        self.actions = actions
    }

    public enum Direction: Sendable, Equatable {
        case left, right
    }

    /// 使用者在卡片上的操作。
    public enum Input: Sendable, Equatable {
        /// 點選項：只移動游標(與終端機一致)。
        case select(SlashPanelOption)
        /// 點滑桿的某個層級。
        case level(Int)
        /// ←/→ 調整。
        case adjust(Direction)
        case action(SlashPanelAction)
    }

    /// 操作要送的按鍵(herdr 鍵名);`nil` = 停用(例如沒有游標列，不知道要移多少)。只會有方向鍵與動作鍵，永不數字。
    public func keys(for input: Input) -> [String]? {
        switch input {
        case .select(let option):
            guard let cursor = options.firstIndex(where: \.isCursor), options.indices.contains(option.index) else { return nil }
            return Self.moves(option.index - cursor, back: "up", forward: "down")
        case .level(let level):
            guard let slider, let current = slider.current, slider.levels.indices.contains(level) else { return nil }
            return Self.moves(level - current, back: "left", forward: "right")
        case .adjust(let direction):
            guard adjustment != nil || slider != nil else { return nil }
            return [direction == .left ? "left" : "right"]
        case .action(let action):
            guard actions.contains(action) else { return nil }
            return [action.key]
        }
    }

    private static func moves(_ distance: Int, back: String, forward: String) -> [String] {
        Array(repeating: distance < 0 ? back : forward, count: abs(distance))
    }
}

/// 面板的一個選項列。
public struct SlashPanelOption: Sendable, Equatable, Identifiable {
    /// 在面板中的位置(0 起算)。
    public var index: Int
    public var label: String
    public var detail: String?
    /// 目前使用中(`✔`、`(current)`)。
    public var isCurrent: Bool
    /// 游標所在列。
    public var isCursor: Bool

    public var id: Int { index }

    public init(index: Int, label: String, detail: String? = nil, isCurrent: Bool = false, isCursor: Bool = false) {
        self.index = index
        self.label = label
        self.detail = detail
        self.isCurrent = isCurrent
        self.isCursor = isCursor
    }
}

/// 層級滑桿：`▲` 所對的層級是目前值。
public struct SlashPanelSlider: Sendable, Equatable {
    public var levels: [String]
    public var current: Int?

    public init(levels: [String], current: Int?) {
        self.levels = levels
        self.current = current
    }
}

/// 面板提示行上的一個動作(`Enter to confirm`、`s to use this session only`、`Esc to cancel`)。
public struct SlashPanelAction: Sendable, Equatable, Hashable {
    /// herdr 鍵名(`enter`、`esc`、`tab`、`space` 或單一字母)。
    public var key: String
    /// 畫面上的說明(agent 的原文);面板沒有提示行時為 `nil`,由畫面依按鍵給標籤。
    public var label: String?

    public init(key: String, label: String?) {
        self.key = key
        self.label = label
    }

    public var isCancel: Bool { key == "esc" }
}

/// 從 pane 畫面解析 slash 面板(§5.6)。只有 Claude 與 Codex 有。
public enum SlashPanelParser {
    public static func parse(screen: String, agentKind: String) -> SlashPanel? {
        let lines = ClaudeTranscriptParser.stripANSI(screen)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "    ") }
            .map { $0.trimmingTrailingWhitespace() }
        switch agentKind {
        case "claude": return claude(lines)
        case "codex": return codex(lines)
        default: return nil
        }
    }

    // MARK: - Claude

    /// 頂端 8 個以上 `▔` 的分隔，之後有 `Esc to (cancel|close|exit|go back)` 的提示行;
    /// 沒有提示行但有選單且沒有輸入框分隔(`─{8,}`)也算(「Switch model?」確認)。
    private static func claude(_ lines: [String]) -> SlashPanel? {
        guard let top = lines.lastIndex(where: isTopRule) else { return nil }
        let body = Array(lines[(top + 1)...])
        let hint = body.lastIndex { $0.contains(/Esc to (cancel|close|exit|go back)/) }
        let content = hint.map { Array(body[..<$0]) } ?? body
        let options = parseOptions(content)
        if hint == nil {
            guard !options.isEmpty, !body.contains(where: { $0.contains(/─{8,}/) }) else { return nil }
        }
        var panel = SlashPanel(title: nil)
        panel.options = options.map(\.option)
        var used = Set(options.map(\.line))

        for (index, line) in content.enumerated() where line.contains("▲") && line.contains("─") {
            used.insert(index)
            if content.indices.contains(index + 1) {
                used.insert(index + 1)
                panel.slider = slider(marker: line, levels: content[index + 1])
            }
            // 軌道正上方的兩端標示(`Faster … Smarter`)屬於滑桿，不是說明。
            if index > 0, !content[index - 1].isBlank, !used.contains(index - 1) {
                used.insert(index - 1)
            }
        }
        if let index = content.firstIndex(where: isAdjustLine) {
            used.insert(index)
            panel.adjustment = content[index].replacing(adjustPhrase, with: "").trimmingCharacters(in: .whitespaces)
        } else if let hint, isAdjustLine(body[hint]) {
            panel.adjustment = ""
        }

        // 標題與說明：第一個選項(或滑桿)之前、沒被用掉的非空行。
        let firstControl = used.min() ?? content.count
        let text = content[..<firstControl].enumerated()
            .filter { !used.contains($0.offset) && !$0.element.isBlank }
            .map { $0.element.trimmingCharacters(in: .whitespaces) }
        panel.title = text.first
        panel.notes = Array(text.dropFirst())

        panel.actions = hint.map { actions(in: body[$0]) } ?? []
        if panel.actions.isEmpty {
            panel.actions = [SlashPanelAction(key: "enter", label: nil), SlashPanelAction(key: "esc", label: nil)]
        }
        return panel
    }

    /// 以 8 個以上 `▔` 開頭的行。Claude Code 2.1.325 會在分隔中間夾文字(用量提醒、`◐ medium · /effort`),
    /// 那段文字不屬於面板(#65 真實錄製)。
    private static func isTopRule(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).prefix { $0 == "▔" }.count >= 8
    }

    private static var adjustPhrase: Regex<Substring> { /←\s*\/?\s*→\s*to adjust/ }

    private static func isAdjustLine(_ line: String) -> Bool {
        line.contains(adjustPhrase)
    }

    /// `▲` 的欄位對到下一行的哪個層級名(落在名稱範圍內，否則取中心最近的)。
    /// 層級只取從 `─` 軌道範圍內開始的字：軌道右邊還有別的控制項(`Ultracode  off`／`Tab to toggle`)。
    private static func slider(marker: String, levels line: String) -> SlashPanelSlider {
        let markerChars = Array(marker)
        let markerColumn = markerChars.firstIndex(of: "▲")
        let track: Range<Int>? = markerColumn.map { column in
            var start = column
            while start > 0, markerChars[start - 1] == "─" { start -= 1 }
            var end = column + 1
            while end < markerChars.count, markerChars[end] == "─" { end += 1 }
            return start..<end
        }
        var levels: [(name: String, start: Int, end: Int)] = []
        var start: Int?
        for (column, character) in (Array(line) + [" "]).enumerated() {
            if character == " " {
                if let begin = start {
                    levels.append((String(Array(line)[begin..<column]), begin, column))
                    start = nil
                }
            } else if start == nil {
                start = column
            }
        }
        if let track {
            levels.removeAll { !track.contains($0.start) }
        }
        let current = markerColumn.flatMap { column in
            levels.firstIndex { $0.start <= column && column < $0.end }
                ?? levels.indices.min { abs(levels[$0].start + levels[$0].end - 2 * column) < abs(levels[$1].start + levels[$1].end - 2 * column) }
        }
        return SlashPanelSlider(levels: levels.map(\.name), current: current)
    }

    /// 提示行以 ` · ` 切成 `<Key> to|for <文字>`。數字鍵永不收(R-C04)。
    private static func actions(in line: String) -> [SlashPanelAction] {
        line.components(separatedBy: " · ").compactMap { part in
            let segment = part.trimmingCharacters(in: .whitespaces)
            guard let match = segment.wholeMatch(of: /(Enter|Return|Esc|Tab|Space|[A-Za-z0-9])\s+(?:to|for)\s+(.+)/) else { return nil }
            let key: String
            switch match.output.1 {
            case "Enter", "Return": key = "enter"
            case "Esc": key = "esc"
            case "Tab": key = "tab"
            case "Space": key = "space"
            default:
                guard let letter = match.output.1.first, letter.isLetter else { return nil }
                key = String(letter).lowercased()
            }
            return SlashPanelAction(key: key, label: String(match.output.2))
        }
    }

    // MARK: - Codex

    /// 頁尾 `Press enter to confirm or esc to go back`;正上方的列是選項，再上方是標題段。
    private static func codex(_ lines: [String]) -> SlashPanel? {
        guard let footer = lines.lastIndex(where: { $0.contains("Press enter to confirm or esc to go back") }) else { return nil }
        var end = footer
        while end > 0, lines[end - 1].isBlank { end -= 1 }
        var start = end
        while start > 0, !lines[start - 1].isBlank { start -= 1 }
        let options = parseOptions(Array(lines[start..<end])).map(\.option)
        guard !options.isEmpty else { return nil }
        var titleEnd = start
        while titleEnd > 0, lines[titleEnd - 1].isBlank { titleEnd -= 1 }
        var titleStart = titleEnd
        while titleStart > 0, !lines[titleStart - 1].isBlank { titleStart -= 1 }
        let text = lines[titleStart..<titleEnd].map { $0.trimmingCharacters(in: .whitespaces) }
        return SlashPanel(
            title: text.first, notes: Array(text.dropFirst()), options: options,
            actions: [SlashPanelAction(key: "enter", label: "confirm"), SlashPanelAction(key: "esc", label: "go back")]
        )
    }

    // MARK: - 選項列

    /// 列：可選游標 `❯`/`›`(或捲動箭頭 `↑`/`↓`)、`NN. 標籤`、2 個以上空白後是細節;`✔`、`(current)` 標示目前值。
    private static func parseOptions(_ lines: [String]) -> [(line: Int, option: SlashPanelOption)] {
        var result: [(line: Int, option: SlashPanelOption)] = []
        for (index, line) in lines.enumerated() {
            guard let match = line.wholeMatch(of: /\s*(?:([❯›↑↓])\s*)?(\d{1,2})\.\s+(.+)/) else { continue }
            var rest = String(match.output.3)
            var isCurrent = false
            for marker in ["✔", "(current)"] where rest.contains(marker) {
                isCurrent = true
                rest = rest.replacingOccurrences(of: marker, with: "")
            }
            let parts = rest.split(separator: /\s{2,}/, maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let cursor = match.output.1.map { $0 == "❯" || $0 == "›" } ?? false
            let option = SlashPanelOption(
                index: result.count, label: parts.first ?? "", detail: parts.count > 1 ? parts[1] : nil,
                isCurrent: isCurrent, isCursor: cursor
            )
            result.append((index, option))
        }
        return result
    }
}
