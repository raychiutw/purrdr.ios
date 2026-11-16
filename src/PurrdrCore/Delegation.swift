import Foundation

/// 委派(subagent 與 workflow)的狀態(行為規格 F10)。
public enum DelegationStatus: String, Sendable, Equatable, Hashable, Codable {
    case running
    case completed
    case failed

    /// 通知的狀態 failed／killed／error／cancelled 是失敗，其他是完成(§4.6)。
    static func reported(_ status: String) -> DelegationStatus {
        ["failed", "killed", "error", "cancelled"].contains(status.lowercased()) ? .failed : .completed
    }
}

/// `Agent`／`Task`／`Workflow` 工具呼叫(對話紀錄中的一個片段)。
public struct DelegationCall: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case subagent
        case workflow
    }

    public var kind: Kind
    public var callID: String?
    /// subagent:`description`;workflow:腳本 meta 的 `name` 或 scriptPath 的名稱。
    public var title: String?
    /// workflow:腳本 meta 的 `description`。
    public var detail: String?
    public var agentType: String?
    public var model: String?
    public var isBackground: Bool

    public init(kind: Kind, callID: String?, title: String?, detail: String? = nil, agentType: String? = nil, model: String? = nil, isBackground: Bool = false) {
        self.kind = kind
        self.callID = callID
        self.title = title
        self.detail = detail
        self.agentType = agentType
        self.model = model
        self.isBackground = isBackground
    }
}

/// Harness 寫的背景任務通知(`<task-notification>`,§4.6)。
public struct TaskNotification: Sendable, Equatable, Hashable, Codable {
    public var taskID: String?
    public var callID: String?
    public var status: String
    public var summary: String?
    public var result: String?
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Int?

    public init(taskID: String?, callID: String?, status: String, summary: String? = nil, result: String? = nil,
                tokens: Int? = nil, toolUses: Int? = nil, durationMs: Int? = nil) {
        self.taskID = taskID
        self.callID = callID
        self.status = status
        self.summary = summary
        self.result = result
        self.tokens = tokens
        self.toolUses = toolUses
        self.durationMs = durationMs
    }
}

/// Subagent 卡(對話畫面的一列)。
public struct SubagentCard: Sendable, Equatable, Hashable {
    public var id: String
    public var callID: String?
    public var title: String
    public var agentType: String?
    public var model: String?
    public var isBackground: Bool
    public var status: DelegationStatus
    public var startedAt: Date?
    /// 秒。
    public var duration: Double?
    public var tokens: Int?
    public var toolCalls: Int?
    /// 結果或回報(hand-back 優先)。
    public var result: String?
    public var agentID: String?

    public init(id: String, callID: String?, title: String, agentType: String? = nil, model: String? = nil, isBackground: Bool = false,
                status: DelegationStatus = .running, startedAt: Date? = nil, duration: Double? = nil, tokens: Int? = nil,
                toolCalls: Int? = nil, result: String? = nil, agentID: String? = nil) {
        self.id = id
        self.callID = callID
        self.title = title
        self.agentType = agentType
        self.model = model
        self.isBackground = isBackground
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
        self.tokens = tokens
        self.toolCalls = toolCalls
        self.result = result
        self.agentID = agentID
    }
}

/// Workflow 卡(對話畫面的一列)。執行中的 phase 與 agent 由 run 檔或 journal 讀取(`WorkflowRun`)。
public struct WorkflowCard: Sendable, Equatable, Hashable {
    public var id: String
    public var callID: String?
    public var name: String
    public var detail: String?
    public var runID: String?
    public var status: DelegationStatus
    public var startedAt: Date?
    public var duration: Double?
    public var tokens: Int?
    public var result: String?

    public init(id: String, callID: String?, name: String, detail: String? = nil, runID: String? = nil, status: DelegationStatus = .running,
                startedAt: Date? = nil, duration: Double? = nil, tokens: Int? = nil, result: String? = nil) {
        self.id = id
        self.callID = callID
        self.name = name
        self.detail = detail
        self.runID = runID
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
        self.tokens = tokens
        self.result = result
    }
}
