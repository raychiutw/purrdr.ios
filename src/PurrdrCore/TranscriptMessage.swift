import Foundation

/// 從對話紀錄解析出的一則訊息(行為規格 §4.0 的共同訊息模型)。各 agent 的解析器都產生這個型別。
public struct TranscriptMessage: Sendable, Equatable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
    }

    /// 穩定的 id:每次讀同一行都得到同一個值，去重才有效。
    public var id: String
    public var role: Role
    public var date: Date?
    public var isSidechain: Bool
    /// 依序的片段。
    public var parts: [TranscriptPart]

    public init(id: String, role: Role, date: Date?, isSidechain: Bool = false, parts: [TranscriptPart]) {
        self.id = id
        self.role = role
        self.date = date
        self.isSidechain = isSidechain
        self.parts = parts
    }
}

/// 訊息中的一個片段。
public enum TranscriptPart: Sendable, Equatable, Codable {
    /// 文字(使用者打的字或 agent 的 markdown)。
    case text(String)
    case thinking(String)
    /// 工具呼叫。`input` 是扁平化的輸入預覽(最多 2,000 字);`path` 是編輯／讀取類工具的檔案路徑。
    case toolCall(id: String?, name: String, input: String, path: String?)
    /// 工具結果(最多 4,000 字)。
    case toolResult(callID: String?, text: String, isError: Bool)
    /// 載入了 skill(`Skill` 工具，或 slash 指令載入的 skill)。
    case skill(name: String)
    /// 系統註記(例如本地 slash 指令的輸出)。
    case note(String)
    /// 使用者附的圖片張數。
    case images(Int)
    /// `Agent`／`Task`／`Workflow` 工具呼叫(F10):成為 subagent 或 workflow 卡。
    case delegation(DelegationCall)
    /// Harness 寫的背景任務通知(§4.6)。只更新卡片，不自成一列。
    case taskNotification(TaskNotification)
    /// Subagent 的 hand-back 報告(§4.6,2.1.294 起)。只更新卡片，不自成一列。
    case handBack(from: String, report: String)
    /// 使用者打的 `!` 指令(`<bash-input>`,已修剪)。
    case shellInput(String)
    /// 上一個 `!` 指令的輸出(`<bash-stdout>`、`<bash-stderr>`)。
    case shellOutput(ShellOutput)
    /// Agent 寫入或修改的主機檔案(#224):成為檔案卡片。
    case agentFile(AgentFileReference)
}

/// Shell `!` 指令的輸出(行為規格 F5.9):已解 HTML 跳脫、去掉 ANSI 色碼與前後換行，各自最多 20,000 字。
public struct ShellOutput: Sendable, Equatable, Codable {
    public var stdout: String
    public var stderr: String
    /// 有任一邊超過上限被截斷。
    public var isTruncated: Bool

    public init(stdout: String, stderr: String, isTruncated: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.isTruncated = isTruncated
    }
}
