import Foundation
import PurrdrCore

/// 已送達的回答：畫面上清楚顯示選了什麼(HIG 20.7:不只改顏色)。
public struct AnsweredPrompt: Sendable, Equatable {
    public var question: String?
    public var choice: String

    public init(question: String?, choice: String) {
        self.question = question
        self.choice = choice
    }
}

/// 回答的提示(對話畫面上的非干擾式標示)。
public enum AnswerNotice: Sendable, Equatable {
    /// 同一個提示超過期限仍在：回答可能沒送到，請檢查 agent。
    case mayNotHaveArrived
    /// 按鍵送不出去。
    case sendFailed
}

/// 選項的樣式規則(HIG 20.7)。
public enum PromptOptionStyle {
    /// 建議選項(prominent):agent 游標所在的那一列，但**不把會結束 agent 的選項設為預設**。
    public static func isRecommended(_ option: PromptOption) -> Bool {
        option.isCursor && !endsAgent(option.label)
    }

    /// 「No, exit」「No, quit」這類會關掉 agent 的選項。
    static func endsAgent(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }
        return words.contains("exit") || words.contains("quit")
    }
}
