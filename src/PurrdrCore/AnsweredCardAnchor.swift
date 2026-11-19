import Foundation

/// 已回答卡片的去留(#213):以回答送出時對話的最後一列為錨點，之後 Agent 寫出可見的文字才收起;
/// 只有 thinking／工具步驟時多留一段時間。
public struct AnsweredCardAnchor: Sendable, Equatable {
    /// 對話的一列。
    public struct Row: Sendable, Equatable {
        public let id: String
        /// 有沒有可見的文字(Agent 回覆、使用者訊息);thinking 與工具步驟沒有。
        public let showsText: Bool

        public init(id: String, showsText: Bool) {
            self.id = id
            self.showsText = showsText
        }
    }

    /// 回答送出後卡片至少顯示多久。
    public static let minimumShowing: TimeInterval = 4
    /// 之後只有工具步驟時，卡片顯示多久。
    public static let stepsOnlyShowing: TimeInterval = 30

    /// 回答送出時對話最後一列的 id;對話還是空的時為 `nil`。
    public let lastEntryID: String?
    public let sentAt: Date

    public init(lastEntryID: String?, sentAt: Date) {
        self.lastEntryID = lastEntryID
        self.sentAt = sentAt
    }

    /// 對話目前是 `rows` 時，卡片是否還要顯示。
    public func isShowing(rows: [Row], at now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(sentAt)
        guard elapsed >= Self.minimumShowing else { return true }
        // 錨點那一列不在了(被修剪)時，剩下的都算新的。
        let start = lastEntryID.flatMap { id in rows.lastIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        let newRows = rows[start...]
        if newRows.contains(where: \.showsText) { return false }
        return newRows.isEmpty || elapsed < Self.stepsOnlyShowing
    }
}
