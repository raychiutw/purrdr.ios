import Foundation

/// 已回答卡片的去留(#213):記下回答送達時對話的最後一列，之後多了新的一列就收起。
public struct AnsweredCardAnchor: Sendable, Equatable {
    /// 回答送達時對話最後一列的 id;對話還是空的時為 `nil`。
    public let lastEntryID: String?

    public init(lastEntryID: String?) {
        self.lastEntryID = lastEntryID
    }

    /// 對話目前最後一列是 `lastEntryID` 時，卡片是否還要顯示。
    public func isShowing(lastEntryID current: String?) -> Bool {
        current == lastEntryID
    }
}
