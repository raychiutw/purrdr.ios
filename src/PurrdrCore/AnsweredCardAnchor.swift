import Foundation

/// 已回答卡片的去留(#213):記下回答送出時對話的最後一列，之後多了新的一列就收起。
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
        rows.last?.id == lastEntryID
    }
}
