import Foundation

/// 一個 Agent 的進度(#307):context 用量百分比與待辦清單，由對話紀錄推得(SSH 與 HTTPS 共用同一條解析)。
public struct AgentProgress: Sendable, Equatable {
    public enum TodoStatus: Sendable, Equatable { case pending, inProgress, completed }

    public struct Todo: Sendable, Equatable {
        public var text: String
        public var status: TodoStatus
        public init(text: String, status: TodoStatus) {
            self.text = text
            self.status = status
        }
    }

    public enum ContextLevel: Sendable, Equatable { case normal, warning, critical }

    public var contextPercent: Int?
    public var todos: [Todo]

    public init(contextPercent: Int? = nil, todos: [Todo] = []) {
        self.contextPercent = contextPercent
        self.todos = todos
    }

    /// 這次解析時讀到的 token 數、模型與上限(只供下一行推算百分比，不參與比較以外的用途)。
    private var tokens: Int?
    private var model: String?
    private var window: Int?
    /// 讀到超過 200k 的 token 數就確定是 1M 視窗；之後壓縮降回 200k 以下也維持。
    private var sawOneMillionWindow = false

    /// 這次解析時讀到的 context token 數(沒讀到是 `nil`)。
    public var contextTokens: Int? { tokens }

    /// context 視窗上限(token 數):紀錄帶的上限優先,否則依模型與是否看過超過 200k 判斷;還沒有 token 數也沒有上限時是 `nil`。
    public var contextLimit: Int? {
        guard tokens != nil || window != nil else { return nil }
        return window ?? (sawOneMillionWindow ? Self.oneMillionWindow : Self.contextWindow(forModel: model))
    }

    public var todoDone: Int { todos.filter { $0.status == .completed }.count }
    public var todoTotal: Int { todos.count }

    /// 70% 起橙、85% 起紅(原型 #t307-d)。
    public var contextLevel: ContextLevel {
        guard let contextPercent else { return .normal }
        return contextPercent >= 85 ? .critical : contextPercent >= 70 ? .warning : .normal
    }

    public var isEmpty: Bool { contextPercent == nil && todos.isEmpty }

    /// 依序看過 `lines`，較晚的值覆蓋較早的。
    public static func latest(in lines: [String], dialect: TranscriptDialect) -> AgentProgress {
        var progress = AgentProgress()
        for line in lines { progress.update(with: line, dialect: dialect) }
        return progress
    }

    /// 以較新的讀取為主，缺的欄位沿用 `older`(列表預覽每次只讀檔尾或附加的部分)。
    public func merging(over older: AgentProgress) -> AgentProgress {
        var merged = self
        if merged.contextPercent == nil { merged.contextPercent = older.contextPercent }
        if merged.todos.isEmpty { merged.todos = older.todos }
        return merged
    }

    public mutating func update(with line: String, dialect: TranscriptDialect) {
        guard let object = ClaudeTranscriptParser.jsonObject(line) else { return }
        dialect.updateProgress(&self, object: object, line: line)
        if let tokens {
            if tokens > Self.standardWindow { sawOneMillionWindow = true }
            contextPercent = min(100, max(0, Int((Double(tokens) * 100 / Double(contextLimit ?? Self.standardWindow)).rounded())))
        }
    }

    private static let standardWindow = 200_000
    private static let oneMillionWindow = 1_000_000

    /// 沒有 status line 資料時的退回算法(#387):模型帶 `[1m]` 用 1M，否則 200k(超過 200k 由呼叫端改判 1M)。
    private static func contextWindow(forModel model: String?) -> Int {
        (model?.lowercased().contains("[1m]") ?? false) ? oneMillionWindow : standardWindow
    }

    mutating func updateClaude(_ object: [String: Any], line: String) {
        // 子 Agent(sidechain)的用量、模型與待辦不屬於這個對話。
        guard object["isSidechain"] as? Bool != true else { return }
        if object["type"] as? String == "user" {
            // `/model` 註記可能把模型換成帶 `[1m]` 的 id。
            var metadata = TranscriptMetadata(model: model, contextTokens: tokens)
            metadata.update(with: line)
            model = metadata.model
            return
        }
        guard object["type"] as? String == "assistant" else { return }
        var metadata = TranscriptMetadata(model: model, contextTokens: tokens)
        metadata.update(with: line)
        model = metadata.model
        tokens = metadata.contextTokens
        let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == "TodoWrite" {
            let items = (block["input"] as? [String: Any])?["todos"] as? [[String: Any]] ?? []
            todos = items.compactMap { Self.todo(text: $0["content"] as? String, status: $0["status"] as? String) }
        }
    }

    mutating func updateCodex(_ object: [String: Any]) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("event_msg", "token_count"):
            guard let info = payload["info"] as? [String: Any],
                  let input = (info["last_token_usage"] as? [String: Any])?["input_tokens"] as? Int, input > 0 else { return }
            tokens = input
            if let size = info["model_context_window"] as? Int, size > 0 { window = size }
        case ("response_item", "function_call"):
            guard payload["name"] as? String == "update_plan",
                  let arguments = payload["arguments"] as? String,
                  let data = arguments.data(using: .utf8),
                  let plan = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["plan"] as? [[String: Any]] else { return }
            todos = plan.compactMap { Self.todo(text: $0["step"] as? String, status: $0["status"] as? String) }
        default:
            break
        }
    }

    private static func todo(text: String?, status: String?) -> Todo? {
        guard let text, !text.isEmpty else { return nil }
        let value: TodoStatus = switch status {
        case "completed": .completed
        case "in_progress": .inProgress
        default: .pending
        }
        return Todo(text: text, status: value)
    }
}
