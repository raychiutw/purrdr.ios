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

    public var todoDone: Int { todos.filter { $0.status == .completed }.count }
    public var todoTotal: Int { todos.count }

    /// 70% 起橙、85% 起紅(原型 #t307-d)。
    public var contextLevel: ContextLevel {
        guard let contextPercent else { return .normal }
        return contextPercent >= 85 ? .critical : contextPercent >= 70 ? .warning : .normal
    }

    public var isEmpty: Bool { contextPercent == nil && todos.isEmpty }

    /// 依序看過 `lines`，較晚的值覆蓋較早的。
    public static func latest(in lines: [String], format: TranscriptFormat) -> AgentProgress {
        var progress = AgentProgress()
        for line in lines { progress.update(with: line, format: format) }
        return progress
    }

    /// 以較新的讀取為主，缺的欄位沿用 `older`(列表預覽每次只讀檔尾或附加的部分)。
    public func merging(over older: AgentProgress) -> AgentProgress {
        var merged = self
        if merged.contextPercent == nil { merged.contextPercent = older.contextPercent }
        if merged.todos.isEmpty { merged.todos = older.todos }
        return merged
    }

    public mutating func update(with line: String, format: TranscriptFormat) {
        guard let object = ClaudeTranscriptParser.jsonObject(line) else { return }
        switch format {
        case .claude: updateClaude(object, line: line)
        case .codex: updateCodex(object)
        default: break
        }
        if let tokens {
            let limit = window ?? Self.contextWindow(forModel: model)
            contextPercent = min(100, max(0, Int((Double(tokens) * 100 / Double(limit)).rounded())))
        }
    }

    private static func contextWindow(forModel model: String?) -> Int {
        (model?.lowercased().contains("[1m]") ?? false) ? 1_000_000 : 200_000
    }

    private mutating func updateClaude(_ object: [String: Any], line: String) {
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

    private mutating func updateCodex(_ object: [String: Any]) {
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
