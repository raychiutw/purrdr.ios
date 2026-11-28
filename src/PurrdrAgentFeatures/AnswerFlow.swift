import Foundation
import PurrdrCore
import Synchronization

/// 回答「需要你」的狀態機(#560):一張需要你卡片從出現到收起的生命週期,收在一個純值型別裡。
///
/// 吃每輪觀察(`Observation`:Agent 狀態、畫面或讀不到、現在時間)與使用者動作(選項、自訂回答開始／取消／送出),
/// 吐出卡片(`prompt`)、鎖定狀態(`inFlight`)、已回答卡片(`lastAnswer`)、提示(`notice`)與下一步動作
/// (`Dispatch` 送哪些輸入、`Follow` 送完後做什麼、`Outcome` 這輪觀察的副作用)。
/// 聊天 model 只執行動作:送按鍵、播觸覺、改輸入框、再輪詢。**不碰主機、不讀時鐘**——時間由呼叫端帶入,
/// 所以規則(#468、#213、R-Q04／05／09)可以用注入的時間與畫面字串直接做表格測試。
///
/// 規則摘要:
/// - 送出前就鎖住所有選項(`inFlight`);之後每輪觀察判定:提示不見了或換成別的 → 已送達(留下已回答卡片);
///   同一個提示超過期限 → 解鎖並提示可能沒送到(R-Q05)。
/// - 答完後 herdr 的 blocked 可能還沒更新:畫面不是選單時,期限內不冒通用鈕(其按鍵會真的打進 Agent,#468)。
/// - 讀不到畫面 = 未知,永不當成新提示,只看逾時。
/// - 打自訂答案時畫面暫時看不出選單,維持原卡片與打的字。
public struct AnswerFlow: Sendable, Equatable {
    // MARK: 對外狀態

    /// 畫面上正在等回答的提示。
    public private(set) var prompt: BlockedPrompt?
    /// 已送出、還在等結果的回答(選項全部鎖住)。
    public private(set) var inFlight: PromptAnswer?
    /// 最近一次已送達的回答(畫面清楚顯示選了什麼);Agent 寫出新的文字後收起(#213)。
    public private(set) var lastAnswer: AnsweredPrompt?
    public private(set) var notice: AnswerNotice?
    /// 正在用輸入框打自訂答案的「Type something.」選項;`nil` = 一般輸入。
    public private(set) var typed: PromptOption?

    /// 回答規則用的 agent 種類(還不知道 agent 時是空字串,走一般規則);由呼叫端在 agent 變動時更新。
    public var agentKind: String

    // MARK: 內部狀態

    private var signature: String?
    private var question: String?
    /// 已送達按鍵的時間與當時對話最後一列(`nil` = 按鍵還沒送完)。
    private var sent: AnsweredCardAnchor?
    private var answeredAnchor: AnsweredCardAnchor?
    /// 答完後到這個時間為止,blocked 但畫面不是選單時視為過時狀態、不顯示通用鈕(#468)。
    private var staleBlockedUntil: Date?
    private var probeRequested = false
    private var draftBeforeTyped = ""
    /// 這次自訂回答打過字了沒有。剛進入時輸入框本來就空,打過字之後再清空才算取消(#127)。
    private var typedHasText = false

    /// 回答期限:max(12 秒, 3 × 輪詢間隔)(blocked 時每 2 秒輪詢;慢輪詢下好答案曾被判逾時,R-Q05)。
    public static let deadline: TimeInterval = max(12, 3 * 2)
    /// 送達後下一題常緊接著出現:這些延遲後各多看一次(R-Q09)。
    public static let followUpPolls: [Duration] = [.milliseconds(400), .milliseconds(800)]

    public init(agentKind: String = "") {
        self.agentKind = agentKind
    }

    // MARK: 每輪觀察

    /// 一輪輪詢看到的事實。
    public struct Observation: Sendable {
        /// herdr 回報 blocked,或 input_pending 且不在工作中。
        public var isBlocked: Bool
        public var isWorking: Bool
        public var hasSession: Bool
        public var now: Date
        /// 目前輸入框的文字(自訂回答被取代而結束時,打到一半的字要留下)。
        public var draft: String

        public init(isBlocked: Bool, isWorking: Bool, hasSession: Bool, now: Date, draft: String) {
            self.isBlocked = isBlocked
            self.isWorking = isWorking
            self.hasSession = hasSession
            self.now = now
            self.draft = draft
        }
    }

    /// 這輪觀察的結果:呼叫端依序執行。
    public struct Outcome: Sendable, Equatable {
        /// 這輪確定 Agent 在等回答(畫面狀態要顯示 blocked)。
        public var agentBlocked = false
        public var haptic: HapticFeedback?
        /// Agent 不再等回答:「請先回答」的提示要收掉。
        public var promptGone = false
        /// 自訂回答因題目變了而結束,輸入框要換成這段文字。
        public var draft: String?

        public init(agentBlocked: Bool = false, haptic: HapticFeedback? = nil, promptGone: Bool = false, draft: String? = nil) {
            self.agentBlocked = agentBlocked
            self.haptic = haptic
            self.promptGone = promptGone
            self.draft = draft
        }
    }

    public enum Step: Sendable, Equatable {
        /// 要讀畫面;讀完呼叫 `observe(screen:dialect:_:)`。
        case readScreen
        /// 不用讀畫面,這輪已結算。
        case settled(Outcome)
    }

    /// 要不要在畫面上找提示(§5.1)。
    ///
    /// - blocked(或 input_pending)每輪都讀;看不出選單就給通用鈕。
    /// - herdr 0.9.5 沒有 `input_pending`:閒置且沒有 session、送出時被告知在等回答、或畫面上已有提示時也讀,
    ///   但**只認資料夾信任**(閒置畫面上對話中的編號清單不是提示)。工作中 = 沒有在等任何回答。
    public mutating func begin(_ observation: Observation) -> Step {
        let probe = !observation.isWorking && (probeRequested || prompt != nil || !observation.hasSession)
        probeRequested = false
        guard observation.isBlocked || probe else {
            return .settled(settle(next: nil, observation))
        }
        return .readScreen
    }

    /// 送出時被告知 agent 在等回答等情況:下一次 `begin` 一定讀畫面。
    public mutating func requestProbe() { probeRequested = true }

    /// 讀畫面的結果。`screen` 為 `nil` = 讀不到(未知)。
    public mutating func observe(screen: String?, dialect: ScreenDialect, _ observation: Observation) -> Outcome {
        observe(parsed: Self.readable(screen).map { Self.parse(screen: $0, dialect: dialect) }, observation)
    }

    /// 全是空白的畫面當成讀不到(#713):重新連線途中讀到的空白不是「畫面上沒有提示」,
    /// 否則送出後會被當成已送達、先顯示「你選了」,其實按鍵沒到。
    public nonisolated static func readable(_ screen: String?) -> String? {
        guard let screen, screen.contains(where: { !$0.isWhitespace }) else { return nil }
        return screen
    }

    /// 解析畫面上的提示:純函式、不碰狀態,所以聊天 model 在背景執行(#585),不佔主執行緒;
    /// 解析次數計入 `parseCount`,供測試確認「不在主執行緒、每輪只解析一次」。
    public nonisolated static func parse(screen: String, dialect: ScreenDialect) -> BlockedPrompt? {
        #if DEBUG
        let onMain = Thread.isMainThread
        parseCounter.withLock { counts in
            var entry = counts[screen, default: (total: 0, onMain: 0)]
            entry.total += 1
            if onMain { entry.onMain += 1 }
            counts[screen] = entry
        }
        #endif
        return BlockedPromptParser.parse(screen: screen, dialect: dialect)
    }

    #if DEBUG
    private nonisolated static let parseCounter = Mutex<[String: (total: Int, onMain: Int)]>([:])
    /// 這份畫面文字到目前為止被 `parse` 解析的次數,與其中在主執行緒上跑的次數(測試用,只在 DEBUG;以畫面文字區分,平行測試互不影響)。
    public nonisolated static func parseCount(forScreen screen: String) -> (total: Int, onMain: Int) {
        parseCounter.withLock { $0[screen] ?? (0, 0) }
    }
    #endif

    /// 讀畫面的結果(已解析)。`parsed` 為外層 `nil` = 讀不到(未知);內層 `nil` = 畫面上沒有提示。
    public mutating func observe(parsed parsedScreen: BlockedPrompt??, _ observation: Observation) -> Outcome {
        guard let parsedScreen else {
            // 讀不到畫面 = 未知:永不當成新提示,只看逾時。剛答完的期限內不冒通用鈕(#468)。
            var outcome = Outcome()
            let isWithinStaleWindow = staleBlockedUntil.map { observation.now < $0 } ?? false
            if observation.isBlocked, prompt == nil, !isWithinStaleWindow { prompt = .unrecognized }
            if prompt != nil { outcome.agentBlocked = true }
            outcome.haptic = checkDeadline(observation.now)
            return outcome
        }
        let parsed = parsedScreen
        if observation.isBlocked, parsed == nil, inFlight != nil, sent == nil, prompt != nil {
            // 送出還沒返回、按鍵可能已到 Agent 而畫面重繪:維持原卡片,不換成通用鈕(#468)。
            return Outcome(agentBlocked: true)
        }
        if observation.isBlocked, parsed == nil, typed != nil, prompt != nil {
            // 打自訂答案時畫面暫時看不出選單(重繪中途):維持原卡片與打的字,不換成通用鈕。
            return Outcome(agentBlocked: true)
        }
        var next = observation.isBlocked ? (parsed ?? .unrecognized) : (parsed?.kind == .trust ? parsed : nil)
        if parsed != nil { staleBlockedUntil = nil }
        if observation.isBlocked, parsed == nil {
            // 答完後 herdr 的 blocked 狀態可能還沒更新:畫面不是選單時不冒出通用鈕,到期限為止。
            if let sent, inFlight != nil { staleBlockedUntil = sent.sentAt.addingTimeInterval(Self.deadline) }
            if let until = staleBlockedUntil, observation.now < until { next = nil }
        }
        var outcome = settle(next: next, observation)
        if next != nil { outcome.agentBlocked = true }
        return outcome
    }

    /// 以新的畫面判定在途的回答,再換上新的提示(同一提示保持原物件)。
    private mutating func settle(next: BlockedPrompt?, _ observation: Observation) -> Outcome {
        var outcome = Outcome()
        if let answer = inFlight, let sent {
            if next == nil || next?.signature != signature {
                // 不再 blocked = 已送達;換成別的提示 = 被取代(通常是下一題),新問題不繼承鎖。
                if case .option(let option) = answer, option.checked != nil {
                    // 勾選只是切換,不是最終的回答。
                } else {
                    lastAnswer = AnsweredPrompt(question: question, choice: Self.choiceText(answer))
                    answeredAnchor = sent
                }
                clearInFlight()
                outcome.haptic = .success
            } else {
                outcome.haptic = checkDeadline(observation.now)
            }
        }
        if next?.signature != prompt?.signature || (next == nil) != (prompt == nil) { prompt = next }
        outcome.promptGone = next == nil
        // 提示換了或不見了(例如在終端機回答掉):自訂回答跟著結束。
        if let typed, !isTypedOption(typed) { outcome.draft = endTyped(keeping: observation.draft) }
        return outcome
    }

    private mutating func checkDeadline(_ now: Date) -> HapticFeedback? {
        guard inFlight != nil, let sentAt = sent?.sentAt, now.timeIntervalSince(sentAt) > Self.deadline else { return nil }
        clearInFlight()
        notice = .mayNotHaveArrived
        return .error
    }

    private mutating func clearInFlight() {
        inFlight = nil
        signature = nil
        question = nil
        sent = nil
    }

    // MARK: 已回答卡片

    /// 已回答卡片:Agent 寫出新的文字,或只有工具步驟但已過保留時間就收起(#213)。
    public mutating func refreshAnsweredCard(rows: [AnsweredCardAnchor.Row], now: Date) {
        guard let anchor = answeredAnchor, !anchor.isShowing(rows: rows, at: now) else { return }
        lastAnswer = nil
        answeredAnchor = nil
    }

    public mutating func dismissNotice() { notice = nil }

    // MARK: 回答

    /// 這個回答現在能不能送:沒有回答在途、提示還在,且有按鍵可送(編號 10 以上不行,R-Q04)。
    public func canAnswer(_ answer: PromptAnswer, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, inFlight == nil, let prompt, AnswerKeys.inputs(for: answer, agentKind: agentKind) != nil else { return false }
        switch answer {
        case .option(let option): return prompt.options.contains(option)
        case .continueMultiSelect: return prompt.isMultiSelect
        case .closePicker: return prompt.kind == .filePicker
        case .generic: return prompt.kind == .unrecognized
        case .typed(let option, _): return prompt.typedAnswerOption(agentKind: agentKind) == option
        }
    }

    /// 開始回答:鎖住所有選項,回傳要送的輸入(不能送回 `nil`)。送完呼叫 `finish(_:result:)`。
    public mutating func begin(answer: PromptAnswer, isReadOnly: Bool) -> [AnswerInput]? {
        guard canAnswer(answer, isReadOnly: isReadOnly), let prompt,
              let inputs = AnswerKeys.inputs(for: answer, agentKind: agentKind) else { return nil }
        inFlight = answer
        signature = prompt.signature
        question = prompt.question
        sent = nil
        staleBlockedUntil = nil
        notice = nil
        return inputs
    }

    /// 按鍵送出的結果。
    public enum SendResult: Sendable, Equatable {
        case sent(lastEntryID: String?, at: Date)
        /// 主機送出前比對發現題目或對話已變更:什麼都沒送出。
        case paneChanged
        case readOnlyDevice
        case failed
    }

    /// 送完之後呼叫端要做的事。
    public struct Follow: Sendable, Equatable {
        public var haptic: HapticFeedback?
        /// 這支裝置是唯讀:卡片改顯示說明。
        public var marksReadOnly = false
        /// 立刻重讀畫面換上目前的題目。
        public var rereadsScreen = false
        /// 這些延遲後各輪詢一次(R-Q09)。
        public var followUpPolls: [Duration] = []

        public init(haptic: HapticFeedback? = nil, marksReadOnly: Bool = false, rereadsScreen: Bool = false, followUpPolls: [Duration] = []) {
            self.haptic = haptic
            self.marksReadOnly = marksReadOnly
            self.rereadsScreen = rereadsScreen
            self.followUpPolls = followUpPolls
        }
    }

    public mutating func finish(_ answer: PromptAnswer, result: SendResult) -> Follow {
        // 送出途中已被觀察結算(提示不見了、期限到)就不再處理。
        guard inFlight == answer else { return Follow() }
        switch result {
        case .sent(let lastEntryID, let at):
            sent = AnsweredCardAnchor(lastEntryID: lastEntryID, sentAt: at)
            return Follow(followUpPolls: Self.followUpPolls)
        case .paneChanged:
            // 什麼都沒送出:題目或對話已變,立刻重讀畫面換上目前的題目。
            clearInFlight()
            notice = .questionChanged
            probeRequested = true
            return Follow(haptic: .error, rereadsScreen: true)
        case .readOnlyDevice:
            clearInFlight()
            return Follow(haptic: .error, marksReadOnly: true)
        case .failed:
            clearInFlight()
            notice = .sendFailed
            return Follow(haptic: .error)
        }
    }

    // MARK: 選項狀態

    /// 這個選項是不是要用輸入框打字回答的「Type something.」。
    public func isTypedOption(_ option: PromptOption) -> Bool {
        prompt?.typedAnswerOption(agentKind: agentKind) == option
    }

    /// 這個「Type something.」現在能不能點(進入自訂回答)。已經在自訂回答時也可點(不做事),所以不看 `typed`。
    public func canBeginTyped(_ option: PromptOption) -> Bool {
        inFlight == nil && isTypedOption(option)
    }

    /// 這個選項的回答是否正在送出(點選的編號,或以它送出的自訂回答)。
    public func isAnswering(_ option: PromptOption) -> Bool {
        switch inFlight {
        case .option(let answered)?, .typed(let answered, _)?: answered == option
        default: false
        }
    }

    /// 「需要你」卡片上一個選項現在的狀態(#424)。
    public func optionState(for option: PromptOption, isReadOnly: Bool) -> PromptOptionState {
        if isAnswering(option) { return .sending }
        if inFlight != nil || isReadOnly { return .disabled }
        let answer = PromptAnswer.option(option)
        return isTypedOption(option) ? (canBeginTyped(option) ? .available : .disabled)
            : (canAnswer(answer, isReadOnly: isReadOnly) ? .available : .disabled)
    }

    /// AskUserQuestion 的問題卡(有「Type something.」或「Chat about this」);權限提示這類選單不算——Esc 會替使用者拒絕。
    public var isQuestionCard: Bool {
        guard let prompt else { return false }
        return prompt.typedAnswerOption(agentKind: agentKind) != nil || prompt.chatOption != nil
    }

    // MARK: 自訂回答(Type something,#120)

    /// 點「Type something.」:不送任何按鍵,改由輸入框打字;原本的草稿先收起來。回傳輸入框要換成的文字(空字串);不能開始回 `nil`。
    public mutating func beginTyped(_ option: PromptOption, draft: String) -> String? {
        guard canBeginTyped(option), typed == nil else { return nil }
        typed = option
        typedHasText = false
        draftBeforeTyped = draft
        return ""
    }

    /// 取消自訂回答,回到一般輸入;回傳輸入框要放回的草稿(沒在自訂回答回 `nil`)。
    public mutating func cancelTyped() -> String? {
        guard typed != nil else { return nil }
        return endTyped(keeping: nil)
    }

    /// 自訂回答時輸入框改了:打過字之後清空 = 取消(#127)。回傳輸入框要放回的草稿(沒結束回 `nil`)。
    public mutating func typedDraftChanged(_ draft: String) -> String? {
        if !draft.isEmpty {
            typedHasText = true
            return nil
        }
        return typedHasText ? endTyped(keeping: nil) : nil
    }

    /// `keeping`:題目變了而結束時,打到一半的字留在輸入框(不蓋成原本的草稿)。
    private mutating func endTyped(keeping: String?) -> String {
        let restored = draftBeforeTyped
        typed = nil
        typedHasText = false
        draftBeforeTyped = ""
        if let keeping, !keeping.isEmpty {
            return restored.isEmpty ? keeping : restored + "\n" + keeping
        }
        return restored
    }

    /// 送出自訂回答的第一步。
    public enum TypedSubmission: Sendable, Equatable {
        /// 題目已經變了:文字留在輸入框(`draft`)並提示。
        case questionChanged(draft: String)
        /// 結束自訂回答,輸入框換成 `draft`,接著送 `answer`(呼叫 `begin(answer:isReadOnly:)`)。
        case send(PromptAnswer, draft: String)
    }

    public mutating func submitTyped(option: PromptOption, text: String, isReadOnly: Bool) -> TypedSubmission {
        let answer = PromptAnswer.typed(option, text: text)
        guard canAnswer(answer, isReadOnly: isReadOnly) else {
            let draft = endTyped(keeping: text)
            notice = .questionChanged
            return .questionChanged(draft: draft)
        }
        return .send(answer, draft: endTyped(keeping: nil))
    }

    /// 自訂回答送不出去(題目變了或按鍵失敗)就回到自訂回答、保留打的字;回傳輸入框要換成的文字。
    public mutating func resumeTypedAfterFailure(option: PromptOption, text: String, currentDraft: String) -> String? {
        guard notice == .sendFailed || notice == .questionChanged, isTypedOption(option) else { return nil }
        guard beginTyped(option, draft: currentDraft) != nil else { return nil }
        return text
    }

    private static func choiceText(_ answer: PromptAnswer) -> String {
        switch answer {
        case .option(let option): option.label
        case .continueMultiSelect: String(localized: "Continue")
        case .closePicker: String(localized: "Close File Picker")
        case .generic(.confirm): String(localized: "Confirm")
        case .generic(.one): "1"
        case .generic(.two): "2"
        case .generic(.escape): String(localized: "Esc")
        case .typed(_, let text): text
        }
    }
}
