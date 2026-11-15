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
}
