/// 輸入框上方一次只顯示的一樣東西(#240)。
public enum ComposerTopAccessory: Sendable, Equatable {
    /// 問題卡片(需要你)。
    case needsYou
    /// 工作中：輸入卡片最上面的停止列(#220,含停止中與停止的結果)。
    case working
    /// Claude Code 的建議提示詞。
    case suggestion(String)

    /// 依優先順序選出要顯示的一樣：需要你 > 工作中(在工作或停止列還在) > 建議;都沒有時為 `nil`。
    public static func choose(needsYou: Bool, isWorking: Bool, showsStopBar: Bool, suggestion: String?) -> ComposerTopAccessory? {
        if needsYou { return .needsYou }
        if isWorking || showsStopBar { return .working }
        return suggestion.map(ComposerTopAccessory.suggestion)
    }
}
