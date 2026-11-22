import Foundation

/// Agent 設定檔的輸入組(ADR-0013、#440):送出 prompt 時的判斷(slash、`!` shell 模式、有沒有送出回條)與回答「需要你」的按鍵。
///
/// 方言是常數表,以 `name` 為身分。**會送按鍵的方言沒驗證過就不開放**(`AnswerDialect.isVerified`):
/// 畫面改讓使用者打字回答或到終端機操作。
public struct InputDialect: Sendable, Equatable {
    public typealias Verification = TranscriptDialect.Verification

    public let name: String
    /// `/名稱` 開頭的文字會讓 Agent 開面板或執行本地指令:不等待、不補 Enter(R-P15、F6.5)。
    public let acceptsSlashCommands: Bool
    /// 草稿以 `!` 開頭是 Agent 的 shell 模式(F6.4):不等待、不補 Enter。
    public let acceptsShellCommands: Bool
    /// 送出後 herdr 看得到 Agent 開始工作的回條。Codex 沒有(共用 app server 下沒有輸入框狀態可看):只靠對話紀錄確認(R-P09)。
    public let givesDeliveryReceipt: Bool
    /// 回答「需要你」的按鍵;`nil` 表示這種 Agent 沒有任何回答方式(畫面只提供終端機)。
    public let answers: AnswerDialect?

    init(
        name: String, acceptsSlashCommands: Bool = false, acceptsShellCommands: Bool = false,
        givesDeliveryReceipt: Bool = true, answers: AnswerDialect? = nil
    ) {
        self.name = name
        self.acceptsSlashCommands = acceptsSlashCommands
        self.acceptsShellCommands = acceptsShellCommands
        self.givesDeliveryReceipt = givesDeliveryReceipt
        self.answers = answers
    }
}

/// 回答提示的按鍵規則(行為規格 §5.5)。
public struct AnswerDialect: Sendable, Equatable {
    /// 編號選項要送的按鍵。
    public enum DigitAnswer: Sendable, Equatable, Hashable {
        /// 數字本身就是回答(R-Q03):多一個 Enter 會回答下一題(Claude)或落進輸入框(Antigravity)。
        case digitAlone
        /// 數字只移動游標,要再按 Enter(Codex)。
        case digitThenEnter
    }

    public let verification: InputDialect.Verification
    public let digitAnswer: DigitAnswer
    /// 選了會把那一列變成行內文字輸入的選項文字(Claude 的 AskUserQuestion 自訂回答,#120):它的數字不是回答,改走打字。
    public let typedAnswerLabel: String?

    public var isVerified: Bool {
        if case .verified = verification { true } else { false }
    }

    init(verification: InputDialect.Verification, digitAnswer: DigitAnswer, typedAnswerLabel: String? = nil) {
        self.verification = verification
        self.digitAnswer = digitAnswer
        self.typedAnswerLabel = typedAnswerLabel
    }
}

extension InputDialect {
    static let claude = InputDialect(
        name: "claude", acceptsSlashCommands: true, acceptsShellCommands: true,
        answers: AnswerDialect(verification: .verified(agentVersion: "Claude Code 2.1.300–2.1.323"), digitAnswer: .digitAlone, typedAnswerLabel: "Type something.")
    )
    static let codex = InputDialect(
        name: "codex", acceptsSlashCommands: true, givesDeliveryReceipt: false,
        answers: AnswerDialect(verification: .verified(agentVersion: "Codex 0.157–0.163"), digitAnswer: .digitThenEnter)
    )
    /// 回答按鍵以 #445 的真實錄製為準:權限提示與 `ask_question` 單按數字即生效。`!` 指令之後的票才開放。
    static let antigravity = InputDialect(
        name: "antigravity", acceptsSlashCommands: true,
        answers: AnswerDialect(verification: .verified(agentVersion: "Antigravity CLI 1.5.14"), digitAnswer: .digitAlone)
    )
    static let grok = InputDialect(
        name: "grok", acceptsSlashCommands: true,
        answers: AnswerDialect(verification: .unverified(documentedFor: "Grok 1.0.52"), digitAnswer: .digitAlone)
    )
    static let piJournal = InputDialect(
        name: "pi-journal",
        answers: AnswerDialect(verification: .unverified(documentedFor: "Pi coding-agent"), digitAnswer: .digitThenEnter)
    )
    /// 其他種類:不當 slash 送、沒有回答方式。
    static let generic = InputDialect(name: "generic")
}
