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
    /// Subagent 卡(`Agent`／`Task` 工具,F10)。
    case subagent(SubagentCard)
    /// Workflow 卡(`Workflow` 工具,F10)。
    case workflow(WorkflowCard)
    /// Shell `!` 指令與它的輸出(F5.9)。
    case shell(ShellRun)

    public var id: String {
        switch self {
        case .user(let item): item.id
        case .agentText(let item): item.id
        case .toolRun(let item): item.id
        case .skill(let item): item.id
        case .note(let item): item.id
        case .subagent(let item): item.id
        case .workflow(let item): item.id
        case .shell(let item): item.id
        }
    }
}

public struct UserBubble: Sendable, Equatable {
    public var id: String
    public var text: String
    public var date: Date?
    public var imageCount: Int
    /// 主機上的圖片路徑(Purrdr 上傳的圖片;畫面依檔名找手機上的副本)。
    public var imagePaths: [String]

    public init(id: String, text: String, date: Date?, imageCount: Int, imagePaths: [String] = []) {
        self.id = id
        self.text = text
        self.date = date
        self.imageCount = imageCount
        self.imagePaths = imagePaths
    }
}

public struct AgentText: Sendable, Equatable {
    public var id: String
    public var markdown: String
    public var date: Date?

    public init(id: String, markdown: String, date: Date?) {
        self.id = id
        self.markdown = markdown
        self.date = date
    }
}

public struct SkillLoaded: Sendable, Equatable {
    public var id: String
    public var name: String
}

/// 使用者在 Claude 輸入 `!指令` 後，在 agent 的 shell 執行的一個指令(行為規格 F5.9)。
public struct ShellRun: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        /// 對話紀錄最後一行就是這個指令：還在執行。
        case running
        /// 下一行不是它的輸出(中斷):沒有記錄輸出。
        case notRecorded
        case recorded(ShellOutput)
    }

    public var id: String
    /// 修剪過的指令(不解 HTML 跳脫)。
    public var command: String
    public var date: Date?
    public var output: Output

    public init(id: String, command: String, date: Date?, output: Output) {
        self.id = id
        self.command = command
        self.date = date
        self.output = output
    }
}

public struct SystemNote: Sendable, Equatable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
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
                switch part {
                case .text(let text): text
                case .shellInput(let command): "! " + command
                default: nil
                }
            }
            // 使用者訊息的圖片路徑不進預覽(F6.6)。
            let candidate = message.role == .user ? UploadedImages.extract(from: texts.joined(separator: "\n")).text : texts.last
            guard let text = candidate else { continue }
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
        /// 委派卡：呼叫 id → 項目位置;agent id 或 workflow run id → 項目位置(通知、hand-back、續跑依此對應)。
        var delegationsByCall: [String: Int] = [:]
        var delegationsByTask: [String: Int] = [:]
        /// 卡片收到的 hand-back 報告(回報內容優先取它，F10)。
        var handBacks: [Int: String] = [:]
        /// 還在等輸出的 shell 區塊(在 `items` 中的位置)。
        var pendingShell: Int?

        mutating func add(_ message: TranscriptMessage) {
            // Shell 指令只和**下一則**訊息配對：下一則不是輸出 → 中斷(沒有記錄輸出,F5.9)。
            let shellAwaitingOutput = pendingShell
            pendingShell = nil
            if let index = shellAwaitingOutput, !message.parts.contains(where: \.isShellOutput), case .shell(var run) = items[index] {
                run.output = .notRecorded
                items[index] = .shell(run)
            }
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
                    if let callID, let index = delegationsByCall[callID] {
                        delegationResult(text: text, isError: isError, date: message.date, at: index)
                    } else {
                        if let resumed = DelegationResultText.resumedAgentID(in: text) { resume(agentID: resumed) }
                        attach(result: text, isError: isError, to: callID)
                    }
                case .delegation(let call):
                    close()
                    addCard(call, id: partID, date: message.date)
                case .taskNotification(let notification):
                    report(notification)
                case .handBack(let from, let text):
                    if let index = delegationsByTask[from] { handBack(text, at: index) }
                case .skill(let name):
                    close()
                    items.append(.skill(SkillLoaded(id: partID, name: name)))
                case .note(let text):
                    close()
                    items.append(.note(SystemNote(id: partID, text: text)))
                case .images(let count):
                    images += count
                case .shellInput(let command):
                    close()
                    items.append(.shell(ShellRun(id: partID, command: command, date: message.date, output: .running)))
                    pendingShell = items.count - 1
                case .shellOutput(let output):
                    if let index = shellAwaitingOutput, case .shell(var run) = items[index] {
                        run.output = .recorded(output)
                        items[index] = .shell(run)
                    }
                }
            }
            let (text, paths) = UploadedImages.extract(from: userTexts.joined(separator: "\n"))
            // Claude 同一張圖有圖片區塊也有來源註記：取兩者較大者，不重複計算。
            let imageCount = max(images, paths.count)
            if !text.isEmpty || imageCount > 0 {
                close()
                items.append(.user(UserBubble(id: message.id, text: text, date: message.date, imageCount: imageCount, imagePaths: paths)))
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

        // MARK: 委派卡(F10「狀態判定」)

        mutating func addCard(_ call: DelegationCall, id: String, date: Date?) {
            switch call.kind {
            case .subagent:
                items.append(.subagent(SubagentCard(
                    id: id, callID: call.callID, title: call.title ?? "Agent", agentType: call.agentType, model: call.model,
                    isBackground: call.isBackground, startedAt: date
                )))
            case .workflow:
                items.append(.workflow(WorkflowCard(id: id, callID: call.callID, name: call.title ?? "Workflow", detail: call.detail, startedAt: date)))
            }
            if let callID = call.callID { delegationsByCall[callID] = items.count - 1 }
        }

        /// 呼叫的工具結果：背景 agent 與 workflow 的啟動結果不算結束(R-W01);前景 agent 的結果就是結束。
        mutating func delegationResult(text: String, isError: Bool, date: Date?, at index: Int) {
            switch items[index] {
            case .subagent(var card):
                if !isError, let agentID = DelegationResultText.asyncAgentID(in: text) {
                    card.agentID = agentID
                    card.isBackground = true
                    delegationsByTask[agentID] = index
                } else {
                    card.status = isError ? .failed : .completed
                    if let start = card.startedAt, let date { card.duration = max(0, date.timeIntervalSince(start)) }
                    let usage = DelegationResultText.usage(in: text)
                    card.tokens = usage.tokens
                    card.toolCalls = usage.toolUses
                    card.result = DelegationResultText.report(in: text)
                    if let agentID = DelegationResultText.agentID(in: text) {
                        card.agentID = agentID
                        delegationsByTask[agentID] = index
                    }
                }
                items[index] = .subagent(card)
            case .workflow(var card):
                if !isError, let runID = DelegationResultText.workflowRunID(in: text) {
                    card.runID = runID
                    delegationsByTask[runID] = index
                } else {
                    card.status = isError ? .failed : .completed
                    if let start = card.startedAt, let date { card.duration = max(0, date.timeIntervalSince(start)) }
                    card.result = DelegationResultText.report(in: text)
                }
                items[index] = .workflow(card)
            default:
                break
            }
        }

        /// 任務通知：依呼叫 id 或 task id(agent id／run id)對應;依序處理，所以最新一則為準。
        mutating func report(_ notification: TaskNotification) {
            guard let index = notification.callID.flatMap({ delegationsByCall[$0] }) ?? notification.taskID.flatMap({ delegationsByTask[$0] }) else { return }
            let status = DelegationStatus.reported(notification.status)
            let duration = notification.durationMs.map { Double($0) / 1000 }
            let result = handBacks[index] ?? notification.result ?? notification.summary
            switch items[index] {
            case .subagent(var card):
                card.status = status
                card.duration = duration ?? card.duration
                card.tokens = notification.tokens ?? card.tokens
                card.toolCalls = notification.toolUses ?? card.toolCalls
                card.result = result
                if card.agentID == nil, let taskID = notification.taskID {
                    card.agentID = taskID
                    delegationsByTask[taskID] = index
                }
                items[index] = .subagent(card)
            case .workflow(var card):
                card.status = status
                card.duration = duration ?? card.duration
                card.tokens = notification.tokens ?? card.tokens
                card.result = result
                items[index] = .workflow(card)
            default:
                break
            }
        }

        mutating func handBack(_ report: String, at index: Int) {
            handBacks[index] = report
            if case .subagent(var card) = items[index], card.status != .running {
                card.result = report
                items[index] = .subagent(card)
            }
        }

        /// `SendMessage` 讓 agent 續跑：變回執行中，直到下一次回報。
        mutating func resume(agentID: String) {
            guard let index = delegationsByTask[agentID], case .subagent(var card) = items[index] else { return }
            card.status = .running
            handBacks[index] = nil
            items[index] = .subagent(card)
        }

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

extension TranscriptPart {
    var isShellOutput: Bool {
        if case .shellOutput = self { true } else { false }
    }
}
