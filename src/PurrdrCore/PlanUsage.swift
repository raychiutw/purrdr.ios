import Foundation

/// 一次讀到的方案用量(#176):各用量週期已用的比例與重置時間。
public struct PlanUsage: Equatable, Sendable {
    public struct Period: Equatable, Sendable {
        public enum Kind: Equatable, Hashable, Sendable { case fiveHour, week }

        public var kind: Kind
        /// 已用比例，0～100(來源可能超出，顯示時夾住)。
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(kind: Kind, usedPercentage: Double, resetsAt: Date?) {
            self.kind = kind
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var periods: [Period]
    /// 來源擷取這份用量的時間。
    public var capturedAt: Date

    public init(periods: [Period], capturedAt: Date) {
        self.periods = periods
        self.capturedAt = capturedAt
    }
}

/// 查一次方案用量的成本。兩者都不花的來源才可以在畫面開著時定期重整。
public struct PlanUsageQueryCost: Equatable, Sendable {
    public var spendsTokens: Bool
    public var needsTransfer: Bool

    public init(spendsTokens: Bool, needsTransfer: Bool) {
        self.spendsTokens = spendsTokens
        self.needsTransfer = needsTransfer
    }

    public var refreshesAutomatically: Bool { !spendsTokens && !needsTransfer }

    /// 不花 token 也不需要傳輸(Demo 主機的本機假資料)。
    public static let free = PlanUsageQueryCost(spendsTokens: false, needsTransfer: false)
    /// 經主機通道讀取：不花 token,但需要傳輸。
    public static let transfer = PlanUsageQueryCost(spendsTokens: false, needsTransfer: true)
}

extension ClaudeUsage {
    /// 換成方案用量(5 小時在前、每週在後;沒有的用量週期不列)。
    public var planUsage: PlanUsage {
        let periods: [PlanUsage.Period] = [(PlanUsage.Period.Kind.fiveHour, fiveHour), (.week, week)].compactMap { kind, value in
            value.map { PlanUsage.Period(kind: kind, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
        }
        return PlanUsage(periods: periods, capturedAt: capturedAt)
    }
}
