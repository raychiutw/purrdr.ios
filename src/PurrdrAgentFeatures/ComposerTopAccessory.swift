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

/// 「需要你」卡片上一個選項的狀態(#424)。
public enum PromptOptionState: Sendable, Equatable {
    /// 可以點。
    case available
    /// 這個選項的回答正在送出:附屬位置放轉圈。
    case sending
    /// 不能點:別的選項在送出中、唯讀裝置，或編號 10 以上要到終端機回答。
    case disabled
}
