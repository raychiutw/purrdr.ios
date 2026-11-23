import Foundation

/// 一次讀到的方案用量(#176):各用量週期已用的比例與重置時間。
public struct PlanUsage: Equatable, Sendable {
    public struct Period: Equatable, Sendable {
        public enum Kind: Equatable, Hashable, Sendable { case fiveHour, week }

        public var kind: Kind
        /// 這份用量屬於哪個模型群組(同一個用量週期可以依群組有多份,Antigravity,#448);Claude、Codex 只有 `.general`。
        public var group: Group
        /// 已用比例，0～100(來源可能超出，顯示時夾住)。
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(kind: Kind, group: Group = .general, usedPercentage: Double, resetsAt: Date?) {
            self.kind = kind
            self.group = group
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        /// 一天的長度;短於一天的用量週期算 5 小時。
        public static let day: TimeInterval = 24 * 60 * 60

        /// 比例夾在 0～100。
        public static func clamped(_ percentage: Double) -> Double { min(max(percentage, 0), 100) }
    }

    /// 用量依哪個維度分群組:一般(整個方案共用)、Antigravity 的 Gemini 模型與第三方模型。
    public enum Group: Equatable, Hashable, Sendable {
        case general, gemini, thirdParty

        /// 模型名稱所屬的群組(Gemini 開頭是 Gemini,其他是第三方);沒有名稱是 `nil`。
        public init?(modelName: String) {
            let name = modelName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = name.lowercased().hasPrefix("gemini") ? .gemini : .thirdParty
        }
    }

    public var periods: [Period]
    /// 來源擷取這份用量的時間。
    public var capturedAt: Date
    /// 來源回報的目前模型所屬群組(Antigravity 的 statusline 有目前模型);沒有時是 `nil`。
    public var activeGroup: Group?

    public init(periods: [Period], capturedAt: Date, activeGroup: Group? = nil) {
        self.periods = periods
        self.capturedAt = capturedAt
        self.activeGroup = activeGroup
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
