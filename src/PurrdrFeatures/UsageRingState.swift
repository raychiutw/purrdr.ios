/// 頂列用量環的三種狀態(#644):一進聊天就是載入中(系統環形載入動畫),
/// 讀到資料換成百分比環,沒有資料或讀取失敗換成空環(#617)。三種的圓圈位置與大小一致。
enum UsageRingState: Equatable {
    case loading
    case value(UsageSummary)
    case empty

    /// - Parameters:
    ///   - summary: 目前拿得到的用量(任一來源先到就先顯示)。
    ///   - isContextLoading: 這個聊天的 session 狀態還沒讀到第一次結果。
    ///   - isPlanLoading: 方案用量還有 Agent 在第一次載入。
    static func make(summary: UsageSummary?, isContextLoading: Bool, isPlanLoading: Bool) -> UsageRingState {
        if let summary { return .value(summary) }
        return isContextLoading || isPlanLoading ? .loading : .empty
    }

    var summary: UsageSummary? {
        if case .value(let summary) = self { summary } else { nil }
    }
}
