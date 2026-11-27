import Foundation

/// 今天的推播用量(#677,spec #674):每個會員每個 UTC 日有一個上限，後台於 UTC 0:00 歸零。
/// 只有數字與時間，顯示文字在 Features。
public struct PushDailyUsage: Sendable, Equatable {
    /// 今日上限(則)。
    public var limit: Int
    /// 今日已送出的則數。
    public var sent: Int
    /// 下次歸零的時間(UTC 0:00 那一刻;顯示時換算成手機時區)。
    public var resetsAt: Date

    public init(limit: Int, sent: Int, resetsAt: Date) {
        self.limit = limit
        self.sent = sent
        self.resetsAt = resetsAt
    }

    /// 已送達上限:當天不會再送。
    public var isLimitReached: Bool { sent >= limit }
}
