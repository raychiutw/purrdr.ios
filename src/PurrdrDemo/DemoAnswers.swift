import Foundation

/// Demo 主機的「需要你」情境(行為規格 F21):各 pane 畫面上的提示、收到按鍵後的變化。
///
/// - weather-app(`w2:p1`)一開始就卡在 Bash 權限提示;依 Claude 的規則只送數字(1–3)就回答掉，變成完成。
/// - 在 ledger(`w1:p1`)輸入觸發語:「ask me」→ 兩題 AskUserQuestion(逐題數字作答)再到檢閱畫面;
///   最後的「Type something.」照真的 Claude(#120):它的數字只把那一列變成行內文字輸入，之後的按鍵(含數字)與
///   `pane.send_text` 都變成那一列的文字(畫面「4. <文字>」),有文字時 Enter 才算回答;Esc 離開文字輸入。
///   「trust」→ 資料夾信任(狀態仍是完成，prompt 被 `agent_input_pending` 拒絕;游標起在「No, exit」)。
/// - ledger 送出 `/model`:畫面開出模型面板(herdr 狀態仍是完成);方向鍵移動游標、←/→ 調整 effort、
///   Enter／`s` 選定游標列、Esc 關閉(#45)。數字不算(真的 Claude 會直接存成預設)。
/// - 送出 `/effort`:effort 滑桿面板(low…max);←/→ 移動層級、Enter 確認(下次開面板從確認的層級開始)、Esc 取消(#34)。
/// - 工作中的 Codex(`w3:p1`)畫面上有正在寫的散文(即時預覽);收到 Esc 或 ctrl+c(停止、強制結束)就變完成(#44)。
/// - ledger 完成時輸入列帶 Claude Code 的灰色建議提示詞(#123,含 ANSI 的畫面才看得出 dim);每送出一個 prompt 換下一句，
///   用完就沒有建議。開面板的 slash 指令不算。
/// 錯的按鍵(例如 Claude 的數字加 Enter)不算回答，方便看出規則錯了。範例文字是自己寫的。
struct DemoAnswers {
    enum Stage: Equatable {
        case bashPermission
        case askColor
        case askSize
        case askReview
        case trust
    }

    private(set) var stages: [String: Stage] = ["w2:p1": .bashPermission]
    /// 開著的 slash 面板(pane → 面板)。
    private(set) var panels: [String: DemoPanel] = [:]
    /// 每個 pane 目前的模型(面板關掉後保留)。
    private var models: [String: Int] = [:]
    /// 每個 pane 目前的 effort 層級(`/effort` 面板確認後保留)。
    private var efforts: [String: Int] = [:]
    /// 在「Type something.」那一列打字中的 pane → 已打的文字。
    private(set) var typing: [String: String] = [:]
    /// AskUserQuestion 每題的選項數(「Type something.」排在它們後面)。
    private static let askOptionCount = 3

    /// 建議提示詞(#123):依序出現的句子(pane → 句子)。
    static let suggestions: [String: [String]] = [
        "w1:p1": ["Add a test for CSV export with commas in the memo", "Run the tests"],
    ]
    /// 每個 pane 已經送出幾個 prompt(決定目前是第幾句建議)。
    private var promptCounts: [String: Int] = [:]

    /// 目前的建議;用完或這個 pane 沒有建議為 `nil`。
    func suggestion(for paneID: String) -> String? {
        let list = Self.suggestions[paneID] ?? []
        let index = promptCounts[paneID] ?? 0
        return index < list.count ? list[index] : nil
    }

    /// 工作中、可以被停止的 pane。
    static let workingPanes: Set<String> = ["w3:p1"]
    /// 已經被停止的 pane(變完成)。
    private(set) var stopped: Set<String> = []

    /// snapshot 上要改的 Agent 狀態(沒列的照範例)。
    var statuses: [String: String] {
        var result: [String: String] = ["w2:p1": "done"]
        for pane in stopped { result[pane] = "done" }
        for (pane, stage) in stages {
            result[pane] = stage == .trust ? "done" : "blocked"
        }
        return result
    }

    /// 在等回答時 `agent.prompt` 的拒絕碼;沒在等為 `nil`。
    func promptRejection(for paneID: String) -> (code: String, message: String)? {
        switch stages[paneID] {
        case nil: nil
        case .trust: ("agent_input_pending", "agent is waiting for input; answer it first")
        default: ("agent_blocked", "agent is blocked waiting for input; answer it first")
        }
    }

    /// 送出的 prompt 是觸發語時進入情境。回傳 `true` = 這是開面板的 slash 指令(不寫進對話紀錄)。
    @discardableResult
    mutating func receivedPrompt(_ text: String, paneID: String) -> Bool {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ask me": stages[paneID] = .askColor
        case "trust": stages[paneID] = .trust
        case "/model":
            let current = models[paneID] ?? 1
            panels[paneID] = .model(DemoModelPanel(current: current, cursor: current))
            return true
        case "/effort":
            panels[paneID] = .effort(DemoEffortPanel(level: efforts[paneID] ?? DemoEffortPanel.defaultLevel))
            return true
        default: break
        }
        promptCounts[paneID, default: 0] += 1
        return false
    }

    /// 收到按鍵：照 Claude 的規則(只送數字;信任提示用方向鍵)推進。
    mutating func receivedKeys(_ keys: [String], paneID: String) {
        if Self.workingPanes.contains(paneID), keys == ["esc"] || keys == ["ctrl+c"] {
            stopped.insert(paneID)
            return
        }
        switch panels[paneID] {
        case .model(var panel)?:
            for key in keys {
                switch key {
                case "up": panel.cursor = max(0, panel.cursor - 1)
                case "down": panel.cursor = min(DemoModelPanel.models.count - 1, panel.cursor + 1)
                case "left": panel.effort = max(0, panel.effort - 1)
                case "right": panel.effort = min(DemoModelPanel.efforts.count - 1, panel.effort + 1)
                case "enter", "s":
                    models[paneID] = panel.cursor
                    panels[paneID] = nil
                    return
                case "esc":
                    panels[paneID] = nil
                    return
                default:
                    break
                }
            }
            panels[paneID] = .model(panel)
            return
        case .effort(var panel)?:
            for key in keys {
                switch key {
                case "left": panel.level = max(0, panel.level - 1)
                case "right": panel.level = min(DemoEffortPanel.levels.count - 1, panel.level + 1)
                case "enter":
                    efforts[paneID] = panel.level
                    panels[paneID] = nil
                    return
                case "esc":
                    panels[paneID] = nil
                    return
                default:
                    break
                }
            }
            panels[paneID] = .effort(panel)
            return
        case nil:
            break
        }
        guard let stage = stages[paneID] else { return }
        if typing[paneID] != nil {
            typeKeys(keys, paneID: paneID, stage: stage)
            return
        }
        switch (stage, keys) {
        case (.askColor, [String(Self.askOptionCount + 1)]), (.askSize, [String(Self.askOptionCount + 1)]):
            typing[paneID] = ""
        case (.bashPermission, ["1"]), (.bashPermission, ["2"]), (.bashPermission, ["3"]):
            stages[paneID] = nil
        case (.askColor, let keys) where keys.count == 1 && ["1", "2", "3"].contains(keys[0]):
            stages[paneID] = .askSize
        case (.askSize, let keys) where keys.count == 1 && ["1", "2", "3"].contains(keys[0]):
            stages[paneID] = .askReview
        case (.askReview, ["1"]), (.askReview, ["2"]):
            stages[paneID] = nil
        case (.trust, ["down", "enter"]), (.trust, ["enter"]):
            // 「No, exit」在 Demo 不真的結束 agent,一樣回到原狀。
            stages[paneID] = nil
        default:
            break
        }
    }

    /// 收到 `pane.send_text`:只有在「Type something.」打字中才進到那一列(否則 Demo 不理會)。
    mutating func receivedText(_ text: String, paneID: String) {
        guard let typed = typing[paneID] else { return }
        typing[paneID] = typed + text
    }

    /// 打字中的按鍵：Enter 在有文字時回答並進下一題，Esc 離開文字輸入，backspace 刪一個字，其他鍵(數字)變成文字。
    private mutating func typeKeys(_ keys: [String], paneID: String, stage: Stage) {
        for key in keys {
            let typed = typing[paneID] ?? ""
            switch key {
            case "enter":
                guard !typed.isEmpty else { continue }
                typing[paneID] = nil
                stages[paneID] = stage == .askColor ? .askSize : .askReview
                return
            case "esc":
                typing[paneID] = nil
                return
            case "backspace":
                typing[paneID] = String(typed.dropLast())
            default:
                if key.count == 1 { typing[paneID] = typed + key }
            }
        }
    }

    /// `pane.read` 的畫面文字。`ansi`:建議提示詞以 SGR 2(dim)包住(同真實 Claude Code 的錄製)。
    func screen(for paneID: String, ansi: Bool = false) -> String {
        switch stages[paneID] {
        case .bashPermission: Self.bashPermission
        case .askColor: Self.ask(header: "☐ Color  ☐ Size", question: "Which color should the chart use?",
                                 options: ["Teal\n     Matches the app icon", "Amber\n     Easy to spot at a glance", "Slate"],
                                 typing: typing[paneID])
        case .askSize: Self.ask(header: "☒ Color  ☐ Size", question: "How large should the chart be?",
                                options: ["Small", "Medium", "Large"], typing: typing[paneID])
        case .askReview: Self.review
        case .trust: Self.trust
        case nil:
            if let panel = panels[paneID] { panel.screen }
            else if Self.workingPanes.contains(paneID) && !stopped.contains(paneID) { Self.codexWorking }
            else { Self.idle(suggestion: suggestion(for: paneID), ansi: ansi) }
        }
    }

    private static let separator = String(repeating: "─", count: 80)

    private static let bashPermission = """
        ⏺ I'll check the cache tests before changing the expiry.

        \(separator)
         Bash command

           swift test --filter HourlyCacheTests
           Run the hourly cache tests

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for swift test commands in /Users/demo/weather-app
           3. No, and tell Claude what to do differently (esc)

        """

    /// `typing`:在「Type something.」那一列打字中(游標移到那一列;還沒打字時照樣顯示「Type something.」)。
    private static func ask(header: String, question: String, options: [String], typing: String?) -> String {
        let rows = options.enumerated().map { index, option in
            (index == 0 && typing == nil ? "❯ " : "  ") + "\(index + 1). \(option)"
        }
        let entry = typing.map { $0.isEmpty ? "Type something." : $0 } ?? "Type something."
        let hint = typing == nil
            ? "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"
            : "Enter to select · Tab/Arrow keys to navigate · ctrl+g to edit · Esc to cancel"
        return """
            \(separator)
             ←  \(header)  ✔ Submit  →

            \(question)

            \(rows.joined(separator: "\n"))
            \(typing == nil ? "  " : "❯ ")\(options.count + 1). \(entry)

            \(hint)

            """
    }

    private static let review = """
        \(separator)
         ←  ☒ Color  ☒ Size  ✔ Submit  →

        Review your answers

         ● Which color should the chart use?
           → Amber
         ● How large should the chart be?
           → Small

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel

        """

    private static let trust = """
        \(separator)
         Accessing workspace:

         /Users/demo/ledger

         Quick safety check: is this a project you made or one you trust? If you are
         not sure, look through the folder before going on.

         Claude Code requires permission to read, edit, and execute files here.

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel

        """

    /// Codex 工作中：正在寫的散文、狀態行、輸入框。
    private static let codexWorking = """
        • Explored
          └ Read sync.swift, README.md

        • The notes sync now writes one Markdown file per notebook, so the
          export folder mirrors the sidebar on your Mac.

        • Working (14s • esc to interrupt)

        › Ask Codex to do anything

        """

    /// 完成的 Claude Code:輸入列是 `❯` + NBSP,有建議時接在後面(灰色)。
    private static func idle(suggestion: String?, ansi: Bool) -> String {
        let input = suggestion.map { ansi ? "\u{1B}[0m\u{1B}[2m\($0)\u{1B}[0m" : $0 } ?? ""
        return """
            ⏺ All set.

            \(separator)
            ❯\u{00A0}\(input)
            \(separator)
              ? for shortcuts

            """
    }
}

/// 開著的 slash 面板。
enum DemoPanel: Equatable {
    case model(DemoModelPanel)
    case effort(DemoEffortPanel)

    var screen: String {
        switch self {
        case .model(let panel): panel.screen
        case .effort(let panel): panel.screen
        }
    }
}

/// Demo 的 `/effort` 面板(#45 依行為規格 §5.6 寫的簡化形狀;真實錄製見 `screens/claude-panel-effort.txt`,
/// 多了 `Faster … Smarter` 標示、軌道右邊的 Ultracode 開關與 `s` 動作):`▲` 所對的層級是目前值。
struct DemoEffortPanel: Equatable {
    static let levels = ["low", "medium", "high", "xhigh", "max"]
    static let defaultLevel = 1

    var level: Int

    var screen: String {
        let indent = "   "
        let names = Self.levels.joined(separator: "     ")
        // `▲` 對在層級名的中間。
        let start = Self.levels[..<level].reduce(0) { $0 + $1.count + 5 }
        let marker = start + Self.levels[level].count / 2
        let rule = String(repeating: "─", count: marker) + "▲" + String(repeating: "─", count: max(0, names.count - marker - 1))
        return """
            ⏺ All set.

            \(String(repeating: "▔", count: 80))
             Effort
             Higher effort spends more time thinking before answering.

            \(indent)\(rule)
            \(indent)\(names)

             ←/→ to adjust · Enter to confirm · Esc to cancel

            """
    }
}

/// Demo 的 `/model` 面板(形狀依行為規格 §5.6 的 Claude 面板)。
struct DemoModelPanel: Equatable {
    static let models: [(name: String, detail: String)] = [
        ("Default (recommended)", "Most capable for complex work"),
        ("Balanced", "Good for everyday tasks"),
        ("Quick", "Fastest for short answers"),
    ]
    static let efforts = ["Low", "Medium", "High"]

    var current: Int
    var cursor: Int
    var effort = 1

    var screen: String {
        let width = Self.models.map(\.name.count).max() ?? 0
        let rows = Self.models.enumerated().map { index, model in
            let mark = index == current ? " ✔" : "  "
            let name = model.name + mark + String(repeating: " ", count: width - model.name.count)
            return (index == cursor ? " ❯ " : "   ") + "\(index + 1). \(name)   \(model.detail)"
        }
        return """
            ⏺ All set.

            \(String(repeating: "▔", count: 80))
             Select model
             Switch between models. Applies to this session and future sessions.

            \(rows.joined(separator: "\n"))

             ◐ \(Self.efforts[effort]) effort ←/→ to adjust

             Enter to set as default · s to use this session only · Esc to cancel

            """
    }
}
