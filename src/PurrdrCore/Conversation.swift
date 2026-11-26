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
    /// 檔案卡片：Agent 寫入或修改的檔案(#224)。
    case agentFile(AgentFileCard)

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
        case .agentFile(let item): item.id
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

    /// 使用者在聊天附加的非圖片檔案(主機上傳資料夾的路徑，#429):畫面以縮小的檔案卡片顯示。
    public var filePaths: [String] { UploadedImages.filePaths(in: text) }
    /// 畫面顯示的文字:拿掉檔案路徑行(`text` 原樣保留，回音配對用)。
    public var displayText: String { UploadedImages.removingFilePaths(from: text) }

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

/// 檔案卡片(GLOSSARY):一個 Agent 檔案參照在對話中的位置。
public struct AgentFileCard: Sendable, Equatable {
    public var id: String
    public var file: AgentFileReference
    public var date: Date?

    public init(id: String, file: AgentFileReference, date: Date?) {
        self.id = id
        self.file = file
        self.date = date
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
    /// 列的 key:以**第一個**步驟命名,分配後不變(後續步驟只原地更新這一列;往上補舊頁併進來時由對話時間軸沿用原本的 key)。
    public var id: String
    /// 展開狀態的 key:與 `id` 相同。
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
        builder.defersSummaries = true
        for message in messages where showSidechain || !message.isSidechain {
            builder.add(message)
        }
        return builder.finish()
    }

    /// 最後一則有文字的 agent 回覆(非 sidechain)的文字;撰寫中預覽以它去重(#208)。
    public static func latestReplyText(in messages: [TranscriptMessage]) -> String? {
        messages.reversed().lazy
            .filter { $0.role == .assistant && !$0.isSidechain }
            .map { $0.parts.compactMap { part in if case .text(let text) = part { text } else { nil } } }
            .first { !$0.isEmpty }?
            .joined(separator: "\n")
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
                .map { String($0).replacingMatches(markdownLeaderPattern, with: "") }
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

    /// 建構器的項目:記錄自上次 `resetTouched()` 以來被改動(原地更新或附加)的最小位置,
    /// 讓增量輸入只重算那一段(#586);其他行為與陣列相同。
    struct TrackedItems: RandomAccessCollection, MutableCollection, ExpressibleByArrayLiteral {
        private(set) var values: [ConversationItem]
        /// 自上次重設以來被改動的最小位置;沒有改動時等於 `count`。
        private(set) var lowestTouched: Int

        init(_ values: [ConversationItem] = []) {
            self.values = values
            lowestTouched = values.count
        }

        init(arrayLiteral elements: ConversationItem...) { self.init(elements) }

        var startIndex: Int { 0 }
        var endIndex: Int { values.count }

        subscript(position: Int) -> ConversationItem {
            get { values[position] }
            set {
                values[position] = newValue
                lowestTouched = Swift.min(lowestTouched, position)
            }
        }

        mutating func append(_ item: ConversationItem) {
            lowestTouched = Swift.min(lowestTouched, values.count)
            values.append(item)
        }

        mutating func resetTouched() { lowestTouched = values.count }
        /// 取代整份(往上補、整份重建):視為全部改動。
        mutating func replaceAll(_ newValues: [ConversationItem]) {
            values = newValues
            lowestTouched = 0
        }
    }

    struct Builder {
        var items = TrackedItems()
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
        /// 呼叫 id → 工具輸入的檔案路徑(Read 圖片的卡片取路徑用)。
        var callPaths: [String: String] = [:]
        /// 已有卡片的產生圖片(同一張圖的項目與事件只算一張)。
        var generatedImages: Set<String> = []
        /// 找不到呼叫的工具結果(呼叫在更舊的頁):往上補舊頁時回頭補上(#586)。
        var orphans: [OrphanResult] = []
        /// 有「只能整份重建才對得上」的跨頁相依(找不到卡片的通知、沒有呼叫的檔案路徑、沒有指令的輸出…),不能增量往上補。
        var needsFullRebuildToPrepend = false

        struct OrphanResult {
            var callID: String?
            var text: String
            var isError: Bool
            var date: Date?
        }

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
            var resultCallID: String?
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
                    if let callID, let path { callPaths[callID] = path }
                case .toolResult(let callID, let text, let isError):
                    resultCallID = callID
                    if let callID, let index = delegationsByCall[callID] {
                        delegationResult(text: text, isError: isError, date: message.date, at: index)
                    } else {
                        let resumed = DelegationResultText.resumedAgentID(in: text)
                        let resumeFailed = resumed.map { !resume(agentID: $0) } ?? false
                        if !attach(result: text, isError: isError, to: callID) {
                            if resumed != nil {
                                needsFullRebuildToPrepend = true
                            } else {
                                orphans.append(OrphanResult(callID: callID, text: text, isError: isError, date: message.date))
                            }
                        } else if resumeFailed {
                            needsFullRebuildToPrepend = true
                        }
                    }
                case .delegation(let call):
                    close()
                    addCard(call, id: partID, date: message.date)
                case .taskNotification(let notification):
                    if !report(notification) { needsFullRebuildToPrepend = true }
                case .handBack(let from, let text):
                    if let index = delegationsByTask[from] { handBack(text, at: index) } else { needsFullRebuildToPrepend = true }
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
                    } else {
                        needsFullRebuildToPrepend = true
                    }
                case .agentFile(var file):
                    if file.path.isEmpty {
                        // Read 圖片：路徑取自同一行工具結果對應的呼叫;呼叫不在視窗內就不顯示。
                        guard let callID = resultCallID, let path = callPaths[callID] else {
                            needsFullRebuildToPrepend = true
                            continue
                        }
                        file.path = path
                    }
                    if file.origin == .generatedImage, !generatedImages.insert(file.path).inserted { continue }
                    // 不結束工具串：同一串的檔案卡片依序排在工具串之後(DESIGN「檔案卡片」)。
                    items.append(.agentFile(AgentFileCard(id: partID, file: file, date: message.date)))
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
            if let openRun, var run = takeToolRun(at: openRun) {
                run.steps.append(step)
                items[openRun] = .toolRun(run)
                refreshSummary(at: openRun)
                return (openRun, run.steps.count - 1)
            }
            items.append(.toolRun(ToolRun(id: step.id, expansionID: step.id, steps: [step], summary: Conversation.summary(of: [step]))))
            openRun = items.count - 1
            return (items.count - 1, 0)
        }

        @discardableResult
        mutating func attach(result: String, isError: Bool, to callID: String?) -> Bool {
            let location: (item: Int, step: Int)?
            if let callID {
                location = callsByID.removeValue(forKey: callID)
            } else {
                location = callsWithoutID.isEmpty ? nil : callsWithoutID.removeFirst()
            }
            guard let location, var run = takeToolRun(at: location.item) else { return false }
            if case .call(var call) = run.steps[location.step].kind {
                call.result = result
                call.isError = isError
                run.steps[location.step].kind = .call(call)
            }
            items[location.item] = .toolRun(run)
            refreshSummary(at: location.item)
            return true
        }

        /// 暫放在被取出的工具串位置上的佔位項目。
        private static let placeholder = ConversationItem.note(SystemNote(id: "", text: ""))

        /// 取出位置上的工具串並以佔位項目換下它:原地修改時 `steps` 不會因為還有第二份參照而整份複製
        /// (長工具串每加一步或配一個結果都複製一次是 O(n²),#510)。呼叫端改完要放回同一個位置。
        private mutating func takeToolRun(at index: Int) -> ToolRun? {
            guard case .toolRun(let run) = items[index] else { return nil }
            items[index] = Self.placeholder
            return run
        }

        /// 工具串變動後的摘要:整批建立時(`defersSummaries`)先記下,由 `settleSummaries()` 或 `finish()` 一次算,
        /// 否則每個步驟都重算整串的摘要(#510)。
        private mutating func refreshSummary(at index: Int) {
            if defersSummaries {
                dirtySummaries.insert(index)
            } else if case .toolRun(var run) = items[index] {
                items[index] = Self.placeholder
                run.summary = Conversation.summary(of: run.steps)
                items[index] = .toolRun(run)
            }
        }

        /// 整批建立時延後摘要;建立完呼叫 `settleSummaries()`。
        var defersSummaries = false
        private var dirtySummaries = Set<Int>()

        /// 算完延後的摘要並回到每步更新的模式(之後逐則追加時摘要立即正確)。
        mutating func settleSummaries() {
            defersSummaries = false
            for index in dirtySummaries { refreshSummary(at: index) }
            dirtySummaries = []
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
        @discardableResult
        mutating func report(_ notification: TaskNotification) -> Bool {
            guard let index = notification.callID.flatMap({ delegationsByCall[$0] }) ?? notification.taskID.flatMap({ delegationsByTask[$0] }) else { return false }
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
            return true
        }

        mutating func handBack(_ report: String, at index: Int) {
            handBacks[index] = report
            if case .subagent(var card) = items[index], card.status != .running {
                card.result = report
                items[index] = .subagent(card)
            }
        }

        /// `SendMessage` 讓 agent 續跑：變回執行中，直到下一次回報。
        @discardableResult
        mutating func resume(agentID: String) -> Bool {
            guard let index = delegationsByTask[agentID], case .subagent(var card) = items[index] else { return false }
            card.status = .running
            handBacks[index] = nil
            items[index] = .subagent(card)
            return true
        }

        // MARK: 往上補舊頁(#586)

        /// 把只含更舊訊息的 `older`(已建好、已 `settleSummaries()`)接在最前面,結果等於對全部訊息重建;
        /// 回傳 false 表示有只能整份重建才對得上的相依,什麼都沒改,呼叫端改用整份重建。
        /// 只處理邊界:舊頁尾端還開著的工具串併入這邊最前面的工具串、這邊找不到呼叫的結果回頭補到舊頁的呼叫、索引整體位移。
        mutating func prepend(_ older: Builder) -> Bool {
            guard !needsFullRebuildToPrepend, !items.isEmpty, older.pendingShell == nil,
                  generatedImages.isDisjoint(with: older.generatedImages) else { return false }
            var older = older

            // 這邊找不到呼叫的結果,依序回頭補到舊頁的呼叫;補不上的留著等更舊的頁。
            var remaining: [OrphanResult] = []
            for orphan in orphans {
                if let callID = orphan.callID, let index = older.delegationsByCall[callID] {
                    older.delegationResult(text: orphan.text, isError: orphan.isError, date: orphan.date, at: index)
                } else if !older.attach(result: orphan.text, isError: orphan.isError, to: orphan.callID) {
                    remaining.append(orphan)
                }
            }

            // 邊界:這邊最前面「不結束工具串」的區段(工具串、檔案卡)裡的第一串,接在舊頁還開著的那串後面。
            var mergedSlot: Int?
            var mergedItemIndex: Int?
            var mergedStepOffset = 0
            if let slot = older.openRun, case .toolRun(var olderRun) = older.items[slot] {
                scan: for (index, item) in items.enumerated() {
                    switch item {
                    case .toolRun(let existing):
                        mergedStepOffset = olderRun.steps.count
                        olderRun.steps += existing.steps
                        olderRun.id = existing.id
                        olderRun.expansionID = existing.id
                        olderRun.summary = Conversation.summary(of: olderRun.steps)
                        older.items[slot] = .toolRun(olderRun)
                        mergedSlot = slot
                        mergedItemIndex = index
                        break scan
                    case .agentFile:
                        continue
                    default:
                        break scan
                    }
                }
            }

            let base = older.items.count
            let mergedIndex = mergedItemIndex
            let slotOfMerged = mergedSlot
            func mapped(_ index: Int) -> Int {
                guard let mergedIndex else { return base + index }
                if index == mergedIndex { return slotOfMerged ?? 0 }
                return index > mergedIndex ? base + index - 1 : base + index
            }
            func mappedCall(_ location: (item: Int, step: Int)) -> (item: Int, step: Int) {
                let step = location.item == mergedIndex ? location.step + mergedStepOffset : location.step
                return (mapped(location.item), step)
            }

            var newItems = older.items
            for (index, item) in items.enumerated() where index != mergedIndex { newItems.append(item) }

            callsByID = older.callsByID.merging(callsByID.mapValues(mappedCall)) { _, existing in existing }
            callsWithoutID = older.callsWithoutID + callsWithoutID.map(mappedCall)
            delegationsByCall = older.delegationsByCall.merging(delegationsByCall.mapValues(mapped)) { _, existing in existing }
            delegationsByTask = older.delegationsByTask.merging(delegationsByTask.mapValues(mapped)) { _, existing in existing }
            var shiftedHandBacks = older.handBacks
            for (index, report) in handBacks { shiftedHandBacks[mapped(index)] = report }
            handBacks = shiftedHandBacks
            openRun = openRun.map(mapped)
            pendingShell = pendingShell.map(mapped)
            callPaths.merge(older.callPaths) { existing, _ in existing }
            generatedImages.formUnion(older.generatedImages)
            orphans = older.orphans + remaining
            needsFullRebuildToPrepend = older.needsFullRebuildToPrepend
            items.replaceAll(newItems.values)
            return true
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

/// 預覽文字行首的 Markdown 標記(標題、清單);只建一次(#585)。
private let markdownLeaderPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: #"^\s*(#+\s*|[-*+]\s+|\d+[.)]\s+)"#)
}()
