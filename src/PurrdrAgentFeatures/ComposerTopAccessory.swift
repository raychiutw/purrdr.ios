/// 輸入框上方一次只顯示的一樣東西(#240)。
public enum ComposerTopAccessory: Sendable, Equatable {
    /// 問題卡片(需要你)。
    case needsYou
    /// 工作中的狀態與停止。
    case working
    /// Claude Code 的建議提示詞。
    case suggestion(String)

    /// 依優先順序選出要顯示的一樣：需要你 > 工作中 > 建議;都沒有時為 `nil`。
    public static func choose(needsYou: Bool, isWorking: Bool, suggestion: String?) -> ComposerTopAccessory? {
        if needsYou { return .needsYou }
        if isWorking { return .working }
        return suggestion.map(ComposerTopAccessory.suggestion)
    }
}
