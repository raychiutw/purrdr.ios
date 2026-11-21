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
    /// 主機送出前比對發現題目(畫面)或對話已變更，什麼都沒送出(#304)。
    case questionChanged
}

/// 選項的樣式(HIG 20.7)。
public enum PromptOptionStyle {
    /// 選項卡的圓角：卡片 16pt 內縮一層。
    package static let cornerRadius = 10.0
}
