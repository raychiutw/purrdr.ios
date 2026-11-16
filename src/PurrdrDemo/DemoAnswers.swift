import Foundation

/// Demo 主機的「需要你」情境(行為規格 F21):各 pane 畫面上的提示、收到按鍵後的變化。
///
/// - weather-app(`w2:p1`)一開始就卡在 Bash 權限提示;依 Claude 的規則只送數字(1–3)就回答掉，變成完成。
/// - 在 ledger(`w1:p1`)輸入觸發語:「ask me」→ 兩題 AskUserQuestion(逐題數字作答)再到檢閱畫面;
///   「trust」→ 資料夾信任(狀態仍是完成，prompt 被 `agent_input_pending` 拒絕;游標起在「No, exit」)。
/// - ledger 送出 `/model`:畫面開出模型面板(herdr 狀態仍是完成);方向鍵移動游標、←/→ 調整 effort、
///   Enter／`s` 選定游標列、Esc 關閉(#45)。數字不算(真的 Claude 會直接存成預設)。
/// - 送出 `/effort`:effort 滑桿面板(low…max);←/→ 移動層級、Enter 確認(下次開面板從確認的層級開始)、Esc 取消(#34)。
/// - 工作中的 Codex(`w3:p1`)畫面上有正在寫的散文(即時預覽);收到 Esc 或 ctrl+c(停止、強制結束)就變完成(#44)。
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
        switch (stage, keys) {
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

    /// `pane.read` 的畫面文字。
    func screen(for paneID: String) -> String {
        switch stages[paneID] {
        case .bashPermission: Self.bashPermission
        case .askColor: Self.ask(header: "☐ Color  ☐ Size", question: "Which color should the chart use?",
                                 options: ["Teal\n     Matches the app icon", "Amber\n     Easy to spot at a glance", "Slate"])
        case .askSize: Self.ask(header: "☒ Color  ☐ Size", question: "How large should the chart be?",
                                options: ["Small", "Medium", "Large"])
        case .askReview: Self.review
        case .trust: Self.trust
        case nil:
            if let panel = panels[paneID] { panel.screen }
            else if Self.workingPanes.contains(paneID) && !stopped.contains(paneID) { Self.codexWorking }
            else { Self.idle }
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

    private static func ask(header: String, question: String, options: [String]) -> String {
        let rows = options.enumerated().map { index, option in
            (index == 0 ? "❯ " : "  ") + "\(index + 1). \(option)"
        }
        return """
            \(separator)
             ←  \(header)  ✔ Submit  →

            \(question)

            \(rows.joined(separator: "\n"))
              \(options.count + 1). Type something.

            Enter to select · Tab/Arrow keys to navigate · Esc to cancel

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

    private static let idle = """
        ⏺ All set.

        \(separator)
        ❯
        \(separator)
          ? for shortcuts

        """
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
