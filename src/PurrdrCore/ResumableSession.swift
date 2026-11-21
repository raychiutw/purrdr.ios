import Foundation

/// 資料夾過去的一個 Agent session,給新增聊天「續接」用(#309;主機服務 `sessions.list`)。
public struct ResumableSession: Sendable, Equatable, Identifiable {
    /// session id,可直接當續接的參數。
    public var id: String
    /// 對話紀錄最後修改時間;主機給的格式看不懂時是 `nil`。
    public var modified: Date?
    /// 第一則使用者訊息的摘要;主機找不到時是 `nil`。
    public var summary: String?

    public init(id: String, modified: Date? = nil, summary: String? = nil) {
        self.id = id
        self.modified = modified
        self.summary = summary
    }
}
