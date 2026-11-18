import Foundation

/// 提示裡的一個選項(行為規格 §5.2、§5.4)。
public struct PromptOption: Sendable, Equatable, Hashable, Identifiable {
    /// 畫面上的編號;資料夾信任這類沒有編號的提示為 `nil`。
    public var number: Int?
    public var label: String
    /// 多選列的勾選狀態;不是勾選列為 `nil`。
    public var checked: Bool?
    /// 選項自己的按鍵(資料夾信任：方向鍵 × n 再 `enter`)。有值時照送。
    public var keys: [String]?
    /// 終端機游標目前停在這一列(agent 的預設選項)。
    public var isCursor: Bool

    public init(number: Int?, label: String, checked: Bool? = nil, keys: [String]? = nil, isCursor: Bool = false) {
        self.number = number
        self.label = label
        self.checked = checked
        self.keys = keys
        self.isCursor = isCursor
    }

    /// 在同一個提示內唯一。
    public var id: String { number.map { "\($0)" } ?? "label:\(label)" }
}

/// 使用者對提示的一個回答。
public enum PromptAnswer: Sendable, Equatable, Hashable {
    case option(PromptOption)
    /// 多選的「繼續」:移到下一題或檢閱畫面。
    case continueMultiSelect
    /// 關閉 Codex 的 `@` 檔案選擇器。
    case closePicker
    /// 沒解析到選項時的通用鈕。
    case generic(GenericAnswer)
    /// Claude 選單的「Type something.」加上使用者打的文字(#120)。
    case typed(PromptOption, text: String)
}

/// 回答時依序送給 pane 的一段輸入。
public enum AnswerInput: Sendable, Equatable {
    /// `pane.send_keys`。
    case keys([String])
    /// `pane.send_text`(原樣打字，不含 Enter)。
    case text(String)
}

extension BlockedPrompt {
    /// Claude 選單最後一個編號選項「Type something.」(AskUserQuestion 的自訂回答,#120);沒有為 `nil`。
    ///
    /// 它的數字不是回答：Claude 收到後把那一列變成行內文字輸入，之後的按鍵都被當成文字。多選的勾選列「Type something」不算。
    public func typedAnswerOption(agentKind: String) -> PromptOption? {
        guard kind == .menu, let last = options.last(where: { $0.number != nil }), last == options.last,
              last.opensTextEntry(agentKind: agentKind) else { return nil }
        return last
    }
}

extension PromptOption {
    /// Claude 的「Type something.」列(不是勾選列)。
    func opensTextEntry(agentKind: String) -> Bool {
        agentKind == "claude" && checked == nil && keys == nil && label == "Type something."
    }
}

/// 沒解析到選項時的通用鈕(行為規格 F8)。
public enum GenericAnswer: String, Sendable, Equatable, Hashable, CaseIterable {
    case confirm
    case one
    case two
    case escape
}

/// 回答提示時送給 pane 的按鍵(herdr 鍵名，`pane.send_keys`;行為規格 §5.5)。
public enum AnswerKeys {
    /// `answer` 要送的按鍵;`nil` = 不能從手機回答(顯示但停用)。
    public static func keys(for answer: PromptAnswer, agentKind: String) -> [String]? {
        switch answer {
        case .option(let option):
            if let keys = option.keys { return keys }
            // 只送數字會把那一列變成文字輸入，不是回答(#120):改走 `.typed`。
            if option.opensTextEntry(agentKind: agentKind) { return nil }
            // 只有 1–9 能用一個按鍵輸入:「10」會先選 1,接著的「0」(與 Enter)又送出一個雜訊 turn(R-Q04)。
            guard let number = option.number, (1...9).contains(number) else { return nil }
            let digit = String(number)
            // 勾選列：數字只切換勾選;多一個 Enter 會多勾一列或送出。
            if option.checked != nil || answersWithDigitAlone(agentKind) { return [digit] }
            return [digit, "enter"]
        case .continueMultiSelect:
            return ["right"]
        case .closePicker:
            return ["esc"]
        case .generic(.confirm):
            return ["enter"]
        case .generic(.one):
            return ["1", "enter"]
        case .generic(.two):
            return ["2", "enter"]
        case .generic(.escape):
            return ["esc"]
        case .typed:
            return nil
        }
    }

    /// `answer` 要依序送的輸入;`nil` = 不能從手機回答。
    ///
    /// 自訂回答(#120):選項的數字(進入文字輸入)→ `send_text` 文字 → `enter`(真實主機驗證過的序列)。
    public static func inputs(for answer: PromptAnswer, agentKind: String) -> [AnswerInput]? {
        guard case .typed(let option, let text) = answer else {
            return keys(for: answer, agentKind: agentKind).map { [.keys($0)] }
        }
        // 行內輸入裡的換行等於 Enter:會用半段文字回答，剩下的字落到下一題。
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard option.opensTextEntry(agentKind: agentKind), let number = option.number, (1...9).contains(number),
              !line.isEmpty else { return nil }
        return [.keys([String(number)]), .text(line), .keys(["enter"])]
    }

    /// 數字本身就是回答的 agent(R-Q03):多一個 Enter 會回答下一題(Claude)或落進輸入框(Antigravity)。
    /// 其他 agent(Codex、Pi、OMP、不認得的)的數字只移動游標，要再按 Enter。
    public static func answersWithDigitAlone(_ agentKind: String) -> Bool {
        ["claude", "grok", "agy", "antigravity"].contains(agentKind)
    }
}
