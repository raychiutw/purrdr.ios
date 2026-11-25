import Foundation
import PurrdrCore

/// 聊天頂列用量環的摘要(#513):這個聊天的 context 與這台主機的方案用量(目前工作階段、每週)裡「最需要注意的一項」。
///
/// 以「已用」比例挑最高的一項(與顯示已用或剩餘無關);同樣高時依每週、目前工作階段、context 的順序。
/// 等級沿用 context 的門檻(70% 起橙、85% 起紅);數字與 VoiceOver 句子跟著「已用／剩餘」設定。
public struct UsageSummary: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case context, currentSession, weekly

        /// 同樣高時的優先順序(小的優先)。
        fileprivate var rank: Int {
            switch self {
            case .weekly: 0
            case .currentSession: 1
            case .context: 2
            }
        }

        public var name: String {
            switch self {
            case .context: String(localized: "Context")
            case .currentSession: String(localized: "Current Session")
            case .weekly: String(localized: "Weekly Limit")
            }
        }
    }

    public var source: Source
    /// 依「已用／剩餘」設定顯示的整數百分比。
    public var percent: Int
    public var display: PlanUsageModel.Display
    public var level: AgentProgress.ContextLevel

    /// 環的填滿比例(0～1),與顯示的數字一致。
    public var fraction: Double { Double(min(max(percent, 0), 100)) / 100 }

    /// VoiceOver:「用量:每週 93%」;顯示剩餘時是「用量:每週 7% 剩餘」。
    public var accessibilityText: String {
        display == .used
            ? String(localized: "Usage: \(source.name) \(percent)%")
            : String(localized: "Usage: \(source.name) \(percent)% left")
    }

    /// - Parameters:
    ///   - contextUsed: context 已用百分比(沒讀到是 `nil`)。
    ///   - planRows: 方案用量的列(`UsageSectionModel` 讀到的,數字已依 `display` 換算)。
    ///   - display: 「已用／剩餘」設定。
    /// - Returns: 都沒有資料時是 `nil`(不顯示用量環)。
    public static func make(contextUsed: Int?, planRows: [PlanUsageRow], display: PlanUsageModel.Display) -> UsageSummary? {
        var candidates: [(source: Source, used: Int)] = []
        if let contextUsed { candidates.append((.context, min(max(contextUsed, 0), 100))) }
        for row in planRows {
            let source: Source = row.period == .week ? .weekly : .currentSession
            let used = display == .used ? row.percent : 100 - row.percent
            candidates.append((source, min(max(used, 0), 100)))
        }
        guard let best = candidates.min(by: { ($0.used, -$0.source.rank) > ($1.used, -$1.source.rank) }) else { return nil }
        return UsageSummary(
            source: best.source, percent: display == .used ? best.used : 100 - best.used, display: display,
            level: AgentProgress(contextPercent: best.used).contextLevel)
    }
}
