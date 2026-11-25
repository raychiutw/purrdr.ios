import Foundation

/// Workflow 裡的一個 agent。
public struct WorkflowAgent: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { agentID ?? label }
    public var agentID: String?
    public var label: String
    public var model: String?
    public var state: DelegationStatus
    public var durationMs: Int?
    public var tokens: Int?
    public var toolCalls: Int?
    /// 目前在做什麼(`lastToolName lastToolSummary`)。
    public var activity: String?
    public var resultPreview: String?
    public var error: String?

    public init(agentID: String?, label: String, model: String? = nil, state: DelegationStatus, durationMs: Int? = nil, tokens: Int? = nil,
                toolCalls: Int? = nil, activity: String? = nil, resultPreview: String? = nil, error: String? = nil) {
        self.agentID = agentID
        self.label = label
        self.model = model
        self.state = state
        self.durationMs = durationMs
        self.tokens = tokens
        self.toolCalls = toolCalls
        self.activity = activity
        self.resultPreview = resultPreview
        self.error = error
    }
}

public struct WorkflowPhase: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var detail: String?
    public var agents: [WorkflowAgent]

    public init(title: String, detail: String? = nil, agents: [WorkflowAgent] = []) {
        self.title = title
        self.detail = detail
        self.agents = agents
    }
}

/// Workflow 的進度(行為規格 §4.6):結束時寫的 run 檔，或執行中持續附加的 journal。
public struct WorkflowRun: Sendable, Equatable, Hashable {
    public var name: String?
    public var summary: String?
    public var isRunning: Bool
    public var phases: [WorkflowPhase]
    public var logs: [String]
    public var durationMs: Int?
    public var agentCount: Int?
    public var totalTokens: Int?

    public init(name: String? = nil, summary: String? = nil, isRunning: Bool, phases: [WorkflowPhase] = [], logs: [String] = [],
                durationMs: Int? = nil, agentCount: Int? = nil, totalTokens: Int? = nil) {
        self.name = name
        self.summary = summary
        self.isRunning = isRunning
        self.phases = phases
        self.logs = logs
        self.durationMs = durationMs
        self.agentCount = agentCount
        self.totalTokens = totalTokens
    }

    public var agents: [WorkflowAgent] { phases.flatMap(\.agents) }
    public var completedAgents: Int { agents.count { $0.state == .completed } }

    /// run 檔(寬鬆解析)。寫一半、解析不出 JSON 物件時回傳 `nil`:呼叫端保留上次結果。
    /// 狀態 running／pending／queued／started／沒有都算執行中。
    public static func parse(runFile data: Data) -> WorkflowRun? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let status = (object["status"] as? String)?.lowercased()
        var phases: [WorkflowPhase] = (object["phases"] as? [[String: Any]] ?? []).enumerated().map { index, phase in
            WorkflowPhase(title: phase["title"] as? String ?? "Phase \(index + 1)", detail: phase["detail"] as? String)
        }
        var phaseByIndex: [Int: Int] = [:]
        for index in phases.indices { phaseByIndex[index] = index }
        for entry in object["workflowProgress"] as? [[String: Any]] ?? [] {
            switch entry["type"] as? String {
            case "workflow_phase":
                guard let index = int(entry["index"]), phaseByIndex[index] == nil else { continue }
                phases.append(WorkflowPhase(title: entry["title"] as? String ?? "Phase \(index + 1)"))
                phaseByIndex[index] = phases.count - 1
            case "workflow_agent":
                let phaseIndex = int(entry["phaseIndex"]) ?? 0
                if phaseByIndex[phaseIndex] == nil {
                    phases.append(WorkflowPhase(title: entry["phaseTitle"] as? String ?? "Phase \(phaseIndex + 1)"))
                    phaseByIndex[phaseIndex] = phases.count - 1
                }
                let activity = [entry["lastToolName"] as? String, entry["lastToolSummary"] as? String].compactMap { $0 }.joined(separator: " ")
                let agent = WorkflowAgent(
                    agentID: entry["agentId"] as? String, label: entry["label"] as? String ?? "Agent", model: entry["model"] as? String,
                    state: agentState(entry["state"] as? String), durationMs: int(entry["durationMs"]), tokens: int(entry["tokens"]),
                    toolCalls: int(entry["toolCalls"]), activity: activity.isEmpty ? nil : activity,
                    resultPreview: entry["resultPreview"] as? String, error: entry["error"] as? String
                )
                phases[phaseByIndex[phaseIndex] ?? 0].agents.append(agent)
            default:
                continue
            }
        }
        return WorkflowRun(
            name: object["workflowName"] as? String, summary: object["summary"] as? String,
            isRunning: status == nil || ["running", "pending", "queued", "started"].contains(status ?? ""),
            phases: phases, logs: object["logs"] as? [String] ?? [], durationMs: int(object["durationMs"]),
            agentCount: int(object["agentCount"]), totalTokens: int(object["totalTokens"])
        )
    }

    /// journal(執行中持續附加):phase 依首次出現順序分組;有 result 即完成(有 error 失敗),其他執行中。
    /// 看不懂的行(撕裂的最後一行)略過。
    public static func parse(journal lines: [String]) -> WorkflowRun {
        var phases: [WorkflowPhase] = []
        var location: [String: (phase: Int, agent: Int)] = [:]
        for line in lines {
            guard let object = ClaudeTranscriptParser.jsonObject(line), let agentID = object["agentId"] as? String else { continue }
            switch object["type"] as? String {
            case "started":
                guard location[agentID] == nil else { continue }
                let title = object["phase"] as? String ?? "Agents"
                let phase = phases.firstIndex { $0.title == title } ?? {
                    phases.append(WorkflowPhase(title: title))
                    return phases.count - 1
                }()
                phases[phase].agents.append(WorkflowAgent(agentID: agentID, label: object["label"] as? String ?? "Agent", state: .running))
                location[agentID] = (phase, phases[phase].agents.count - 1)
            case "result":
                guard let (phase, agent) = location[agentID] else { continue }
                if let error = object["error"] as? String, !error.isEmpty {
                    phases[phase].agents[agent].state = .failed
                    phases[phase].agents[agent].error = error
                } else {
                    phases[phase].agents[agent].state = .completed
                    phases[phase].agents[agent].resultPreview = object["result"] as? String
                }
            default:
                continue
            }
        }
        return WorkflowRun(isRunning: true, phases: phases)
    }

    /// state done／completed／cached 完成，error／failed／killed 失敗，其他執行中。
    static func agentState(_ state: String?) -> DelegationStatus {
        switch state?.lowercased() {
        case "done", "completed", "cached": .completed
        case "error", "failed", "killed": .failed
        default: .running
        }
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

/// 讀 workflow 進度的結果。
public enum WorkflowRead: Sendable, Equatable {
    /// checksum 與上次相同：沒有傳內容。
    case unchanged
    case run(checksum: String, data: Data)
    case journal(checksum: String, lines: [String])
}

extension TranscriptReader {
    /// 讀 workflow 進度(R-W03):run 檔只在結束時寫，所以有 run 檔讀 run 檔，否則讀 journal。
    /// 先比對 checksum,與 `knownChecksum` 相同就不傳內容。
    ///
    /// - Throws: `.absent`(兩個都還沒有)、`.invalidReference`(id 或資料夾不安全，不執行指令)。
    public func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        guard ClaudeTranscript.isSafeDelegationID(runID), ClaudeTranscript.isValidFolder(sessionFolder) else {
            throw TranscriptReadError.invalidReference
        }
        return try await connection.readWorkflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
    }

    /// `readWorkflow` 的腳本輸出實作(連線的型別化操作預設實作用)。
    package func wireWorkflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        let output = try await run(.readWorkflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum ?? ""))
        guard let newline = output.stdout.firstIndex(of: 0x0A) else { throw TranscriptReadError.changed }
        let checksum = String(decoding: output.stdout[..<newline], as: UTF8.self)
        if checksum == knownChecksum { return .unchanged }
        let content = output.stdout[output.stdout.index(after: newline)...]
        if checksum.hasPrefix("run ") { return .run(checksum: checksum, data: Data(content)) }
        guard checksum.hasPrefix("journal ") else { throw TranscriptReadError.changed }
        return .journal(checksum: checksum, lines: String(decoding: content, as: UTF8.self).split(separator: "\n").map(String.init))
    }
}
