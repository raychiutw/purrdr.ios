import Foundation

/// 對話畫面上的一個項目(行為規格 F5.8)。由對話紀錄的訊息轉成。
public enum ConversationItem: Sendable, Equatable, Identifiable {
    /// 使用者的訊息(泡泡)。
    case user(UserBubble)
    /// agent 的文字(markdown,全寬，不是泡泡)。
    case agentText(AgentText)
    /// 連續的工具呼叫與 thinking,收合成一行摘要。
    case toolRun(ToolRun)
    /// 「已載入 skill:<名稱>」。
    case skill(SkillLoaded)
    /// 系統註記(置中膠囊)。
    case note(SystemNote)

    public var id: String {
        switch self {
        case .user(let item): item.id
        case .agentText(let item): item.id
        case .toolRun(let item): item.id
        case .skill(let item): item.id
        case .note(let item): item.id
        }
    }
}

public struct UserBubble: Sendable, Equatable {
    public var id: String
    public var text: String
    public var date: Date?
    public var imageCount: Int
}

public struct AgentText: Sendable, Equatable {
    public var id: String
    public var markdown: String
    public var date: Date?
}

public struct SkillLoaded: Sendable, Equatable {
    public var id: String
    public var name: String
}

public struct SystemNote: Sendable, Equatable {
    public var id: String
    public var text: String
}

/// 工具串。
public struct ToolRun: Sendable, Equatable {
    /// 列的 key:以**最後一個**項目命名(往上翻頁會把舊項目加在前面，以第一個命名會讓列跳動)。
    public var id: String
    /// 展開狀態的 key:以**第一個**項目命名(串變長仍穩定)。
    public var expansionID: String
    public var steps: [ToolStep]
    public var summary: ToolRunSummary
}

public struct ToolStep: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case thinking(String)
        case call(ToolCallStep)
    }

    public var id: String
    public var kind: Kind
}

public struct ToolCallStep: Sendable, Equatable {
    public var name: String
    public var category: ToolCategory
    public var input: String
    public var path: String?
    /// 工具結果;還沒有結果時為 `nil`。
    public var result: String?
    public var isError: Bool
}

/// 工具分類(行為規格 F5.8,依工具名小寫)。
public enum ToolCategory: Sendable, Equatable {
    case command, edit, read, search, fetch, todo, question, agent, other
}

/// 工具串的摘要計數。畫面依此組出「Ran 3 commands · Edited 2 files」這類文字。
public struct ToolRunSummary: Sendable, Equatable {
    public var thoughts: Int
    public var commands: Int
    /// 依路徑去重。
    public var editedFiles: Int
    public var readFiles: Int
    public var searches: Int
    public var fetches: Int
    public var updatedTodos: Bool
    public var questions: Int
    public var otherTools: Int
    public var failures: Int

    public init(
        thoughts: Int = 0, commands: Int = 0, editedFiles: Int = 0, readFiles: Int = 0, searches: Int = 0,
        fetches: Int = 0, updatedTodos: Bool = false, questions: Int = 0, otherTools: Int = 0, failures: Int = 0
    ) {
        self.thoughts = thoughts
        self.commands = commands
        self.editedFiles = editedFiles
        self.readFiles = readFiles
        self.searches = searches
        self.fetches = fetches
        self.updatedTodos = updatedTodos
        self.questions = questions
        self.otherTools = otherTools
        self.failures = failures
    }
}

/// 對話紀錄訊息 → 畫面項目。
public enum Conversation {
    /// 訊息 → 畫面項目(行為規格 F5.8):
    /// - 使用者泡泡只在有可讀文字或圖片時產生(只含工具結果的使用者行不產生列)。
    /// - 連續的工具呼叫與 thinking 折成一個工具串，遇到任何可讀內容(文字、skill、註記)結束。
    /// - 工具結果依 `tool_use_id` 配對;沒有 id 的依先進先出配給沒有 id 的呼叫。
    /// - sidechain 訊息預設隱藏。
    public static func items(from messages: [TranscriptMessage], showSidechain: Bool = false) -> [ConversationItem] {
        var builder = Builder()
        for message in messages where showSidechain || !message.isSidechain {
            builder.add(message)
        }
        return builder.finish()
    }

    /// 列表預覽(行為規格 §4.7):最後一則非 sidechain、非純工具、非系統的訊息;去掉 `**`、`__`、反引號、
    /// 開頭的 `#` 與清單記號，壓縮空白，截 200 字。
    public static func preview(of messages: [TranscriptMessage]) -> MessagePreview? {
        for message in messages.reversed() where !message.isSidechain && message.role != .system {
            let texts = message.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            guard let text = texts.last else { continue }
            let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).replacingMatches(#"^\s*(#+\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "") }
                .joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !plain.isEmpty else { continue }
            return MessagePreview(text: plain.truncated(to: 200), date: message.date, isFromUser: message.role == .user)
        }
        return nil
    }

    /// 依工具名(小寫)分類。
    static func category(ofTool name: String) -> ToolCategory {
        switch name.lowercased() {
        case "bash", "bashoutput", "exec", "exec_command", "shell", "local_shell", "container.exec", "write_stdin",
             "run_terminal_command", "run_command": .command
        case "write", "edit", "multiedit", "notebookedit", "apply_patch", "search_replace", "edit_file": .edit
        case "read", "read_file", "view_file": .read
        case "grep", "glob", "find", "ls", "websearch", "toolsearch", "web_search", "tool_search", "list_dir", "search_web": .search
        case "webfetch", "fetch", "web_fetch": .fetch
        case "todowrite", "taskcreate", "taskupdate", "update_plan", "todo": .todo
        case "askuserquestion", "ask_question": .question
        case "agent", "task": .agent
        default: .other
        }
    }

    /// MCP 工具 `mcp__X__Y` 顯示為「X Y」。
    static func displayName(ofTool name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.dropFirst(5).split(separator: "__").joined(separator: " ")
    }

    private struct Builder {
        var items: [ConversationItem] = []
        /// 正在累積的工具串(在 `items` 中的位置)。
        var openRun: Int?
        /// 呼叫 id → (項目位置, 步驟位置),結果可以晚到。
        var callsByID: [String: (item: Int, step: Int)] = [:]
        var callsWithoutID: [(item: Int, step: Int)] = []

        mutating func add(_ message: TranscriptMessage) {
            var images = 0
            var userTexts: [String] = []
            for (index, part) in message.parts.enumerated() {
                let partID = "\(message.id):\(index)"
                switch part {
                case .text(let text) where message.role == .user:
                    userTexts.append(text)
                case .text(let text):
                    close()
                    items.append(.agentText(AgentText(id: partID, markdown: text, date: message.date)))
                case .thinking(let text):
                    append(ToolStep(id: partID, kind: .thinking(text)))
                case .toolCall(let callID, let name, let input, let path):
                    let call = ToolCallStep(name: Conversation.displayName(ofTool: name), category: Conversation.category(ofTool: name),
                                            input: input, path: path, result: nil, isError: false)
                    let location = append(ToolStep(id: partID, kind: .call(call)))
                    if let callID { callsByID[callID] = location } else { callsWithoutID.append(location) }
                case .toolResult(let callID, let text, let isError):
                    attach(result: text, isError: isError, to: callID)
                case .skill(let name):
                    close()
                    items.append(.skill(SkillLoaded(id: partID, name: name)))
                case .note(let text):
                    close()
                    items.append(.note(SystemNote(id: partID, text: text)))
                case .images(let count):
                    images += count
                }
            }
            if !userTexts.isEmpty || images > 0 {
                close()
                items.append(.user(UserBubble(id: message.id, text: userTexts.joined(separator: "\n"), date: message.date, imageCount: images)))
            }
        }

        @discardableResult
        mutating func append(_ step: ToolStep) -> (item: Int, step: Int) {
            if let openRun, case .toolRun(var run) = items[openRun] {
                run.steps.append(step)
                run.id = step.id
                items[openRun] = .toolRun(run)
                return (openRun, run.steps.count - 1)
            }
            items.append(.toolRun(ToolRun(id: step.id, expansionID: step.id, steps: [step], summary: ToolRunSummary())))
            openRun = items.count - 1
            return (items.count - 1, 0)
        }

        mutating func attach(result: String, isError: Bool, to callID: String?) {
            let location: (item: Int, step: Int)?
            if let callID {
                location = callsByID.removeValue(forKey: callID)
            } else {
                location = callsWithoutID.isEmpty ? nil : callsWithoutID.removeFirst()
            }
            guard let location, case .toolRun(var run) = items[location.item],
                  case .call(var call) = run.steps[location.step].kind else { return }
            call.result = result
            call.isError = isError
            run.steps[location.step].kind = .call(call)
            items[location.item] = .toolRun(run)
        }

        mutating func close() { openRun = nil }

        func finish() -> [ConversationItem] {
            items.map { item in
                guard case .toolRun(var run) = item else { return item }
                run.summary = Conversation.summary(of: run.steps)
                return .toolRun(run)
            }
        }
    }

    static func summary(of steps: [ToolStep]) -> ToolRunSummary {
        var summary = ToolRunSummary()
        var editedPaths = Set<String>()
        for step in steps {
            switch step.kind {
            case .thinking:
                summary.thoughts += 1
            case .call(let call):
                if call.isError { summary.failures += 1 }
                switch call.category {
                case .command: summary.commands += 1
                case .edit:
                    if let path = call.path {
                        if editedPaths.insert(path).inserted { summary.editedFiles += 1 }
                    } else {
                        summary.editedFiles += 1
                    }
                case .read: summary.readFiles += 1
                case .search: summary.searches += 1
                case .fetch: summary.fetches += 1
                case .todo: summary.updatedTodos = true
                case .question: summary.questions += 1
                case .agent: break
                case .other: summary.otherTools += 1
                }
            }
        }
        return summary
    }
}
