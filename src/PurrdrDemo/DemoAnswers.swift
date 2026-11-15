import Foundation

/// Demo 主機的「需要你」情境(行為規格 F21):各 pane 畫面上的提示、收到按鍵後的變化。
///
/// - weather-app(`w2:p1`)一開始就卡在 Bash 權限提示;依 Claude 的規則只送數字(1–3)就回答掉，變成完成。
/// - 在 ledger(`w1:p1`)輸入觸發語:「ask me」→ 兩題 AskUserQuestion(逐題數字作答)再到檢閱畫面;
///   「trust」→ 資料夾信任(狀態仍是完成，prompt 被 `agent_input_pending` 拒絕;游標起在「No, exit」)。
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

    /// 送出的 prompt 是觸發語時進入情境。
    mutating func receivedPrompt(_ text: String, paneID: String) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ask me": stages[paneID] = .askColor
        case "trust": stages[paneID] = .trust
        default: break
        }
    }

    /// 收到按鍵：照 Claude 的規則(只送數字;信任提示用方向鍵)推進。
    mutating func receivedKeys(_ keys: [String], paneID: String) {
        if Self.workingPanes.contains(paneID), keys == ["esc"] || keys == ["ctrl+c"] {
            stopped.insert(paneID)
            return
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
        case nil: Self.workingPanes.contains(paneID) && !stopped.contains(paneID) ? Self.codexWorking : Self.idle
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
