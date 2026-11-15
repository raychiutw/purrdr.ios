import Foundation

/// 送出 prompt 的結果(行為規格 §3.6 的三態，加上「什麼都沒送出」的情況)。
public enum PromptOutcome: Sendable, Equatable {
    /// 已送達：主機觀察到 agent 開始工作或停下來問問題。
    case delivered
    /// Slash 指令已交給主機(不等待、不確認，R-P15)。
    case submittedCommand
    /// 沒有反應:herdr 送了文字，但 agent 沒有接住(停滯);文字可能還在 agent 的輸入框裡。
    case noResponse
    /// 無法確認：可能已送到，也可能沒有。**不可自動重送**(§7.3)。
    case unconfirmed(UnconfirmedReason)
    /// agent 正在等一個問題(`agent_blocked`/`agent_input_pending`):什麼都沒送出。
    case needsAnswer
    /// herdr 拒絕了請求，什麼都沒送出。訊息是 herdr 原文。
    case rejected(message: String)
}

/// 無法確認的原因。
public enum UnconfirmedReason: Sendable, Equatable {
    /// 連線在送出時斷了(或期限到):訊息可能已到，重送前先看聊天(#83)。
    case connectionLost
    /// 只知道文字寫進了終端機，agent 沒有反應，也不能安全地補 Enter:訊息可能卡在終端機裡。
    case mayBeInTerminal
    /// 已送進 Codex,但只能靠對話紀錄確認(R-P09)。
    case codexNoReceipt
}

/// 中斷的結果(F6.7)。
public enum StopOutcome: Sendable, Equatable {
    case stopped
    /// 3 秒後仍在工作。
    case stillWorking
    /// 連 Esc 都送不出去。
    case failed
}

/// 送出 prompt、補 Enter 與中斷的規則(行為規格 F6.5、F6.7、§3.6、§7.3)。
///
/// - prompt 路徑:`agent.prompt` 帶 `wait: {until: [working, blocked], timeout_ms: 8000}`,我方期限 8+20 秒。
/// - **連線層失敗永不重送**:主機可能已經執行，只是回應遺失。
/// - fallback Enter 只在「主機只回報寫進終端機」、agent 原本不在工作、3.5 秒內沒有變化、
///   且**新鮮讀到** `idle`/`done` 時送一個;永不對 `blocked` 補 Enter(R-P03)。
/// - Slash 指令不等待、不補 Enter(R-P15)。
public struct PromptDelivery: Sendable {
    private let client: HerdrClient
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(client: HerdrClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.sleep = sleep
    }

    /// 送出 `text` 給 `agent`(呼叫端已用新鮮的 snapshot 確認過目標)。
    public func send(_ text: String, to agent: Agent) async -> PromptOutcome {
        if Self.isSlashCommand(text, kind: agent.kind) {
            return await sendSlashCommand(text, to: agent)
        }
        let reply: PromptReply
        do {
            reply = try await client.prompt(target: agent.paneID, text: text, wait: .seconds(8))
        } catch let error as HerdrError {
            return outcome(of: error, agent: agent)
        } catch {
            return agent.kind == "codex" ? .unconfirmed(.codexNoReceipt) : .unconfirmed(.connectionLost)
        }
        guard reply.writtenOnly else { return .delivered }
        if agent.kind == "codex" { return .unconfirmed(.codexNoReceipt) }
        // agent 原本就在工作:prompt 只會排隊，不等(F6.5)。
        if agent.status == .working { return .delivered }
        return await confirmWrittenPrompt(paneID: agent.paneID)
    }

    /// Slash 指令：不帶 wait、絕不補 Enter(R-P15)。確認(面板、對話紀錄、agent 反應)由 slash 那張票做。
    private func sendSlashCommand(_ text: String, to agent: Agent) async -> PromptOutcome {
        do {
            _ = try await client.prompt(target: agent.paneID, text: text, wait: nil)
            return .submittedCommand
        } catch let error as HerdrError {
            if case .herdr = error { return outcome(of: error, agent: agent) }
            return .unconfirmed(.connectionLost)
        } catch {
            return .unconfirmed(.connectionLost)
        }
    }

    private func outcome(of error: HerdrError, agent: Agent) -> PromptOutcome {
        switch error {
        case .herdr(code: "agent_blocked", _), .herdr(code: "agent_input_pending", _):
            return .needsAnswer
        case .herdr(code: "timeout", _), .herdr(code: "agent_prompt_stalled", _):
            // Codex 在共用 app server 下可能沒有輸入框狀態可看：只靠對話紀錄確認(R-P09)。
            return agent.kind == "codex" ? .unconfirmed(.codexNoReceipt) : .noResponse
        case .herdr(_, let message):
            return .rejected(message: message)
        case .noResponse, .malformedResponse, .deadlineExceeded:
            // 傳輸層失敗 ≠ 停滯：不知道有沒有送到(§3.6、R-P05)。
            return agent.kind == "codex" ? .unconfirmed(.codexNoReceipt) : .unconfirmed(.connectionLost)
        }
    }

    /// 主機只知道文字寫進了終端機：等 3.5 秒看 agent 有沒有開始工作;沒有，就新鮮地讀一次狀態，
    /// **只有主機明確回報 `idle` 或 `done`** 才補一個 Enter,再等 2.5 秒(F6.5、R-P03)。
    private func confirmWrittenPrompt(paneID: String) async -> PromptOutcome {
        let reacting: [AgentStatus] = [.working, .blocked]
        switch try? await client.waitForAgent(target: paneID, until: reacting, timeout: .milliseconds(3500)) {
        case true?: return .delivered
        case false?: break
        case nil: return .unconfirmed(.mayBeInTerminal)
        }
        guard let status = try? await client.snapshot().agents.first(where: { $0.paneID == paneID })?.status,
              status == .idle || status == .done else {
            return .unconfirmed(.mayBeInTerminal)
        }
        do {
            try await client.sendKeys(paneID: paneID, keys: ["enter"])
        } catch {
            return .unconfirmed(.mayBeInTerminal)
        }
        let reacted = (try? await client.waitForAgent(target: paneID, until: reacting, timeout: .milliseconds(2500))) ?? false
        return reacted ? .delivered : .unconfirmed(.mayBeInTerminal)
    }

    /// 會讓 agent 打開面板或執行本地指令的 slash 指令:`/` 接字母開頭的名稱，之後是空白或結尾(F6.5)。
    /// 只有認得 slash 指令的 agent(Claude Code、Codex、Grok、Antigravity)才算。
    public static func isSlashCommand(_ text: String, kind: String) -> Bool {
        guard ["claude", "codex", "grok", "antigravity"].contains(kind), text.hasPrefix("/") else { return false }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let first = name.first, first.isASCII, first.isLetter else { return false }
        return !name.contains("/")
    }

    // MARK: - 中斷

    /// 停止(F6.7):送**一個** Esc(第二個會打開 Claude 的回溯選單),之後每 500ms 讀狀態、最多 3 秒，
    /// 等它離開 working;讀不到狀態視為成功。主機會把不認得的鍵名當文字收下，所以「鍵被接受」不代表停了。
    /// 呼叫端保證目標不是 blocked 的 pane(中斷可能把問題關掉)。
    public func stop(paneID: String) async -> StopOutcome {
        do {
            try await client.sendKeys(paneID: paneID, keys: ["esc"])
        } catch {
            return .failed
        }
        for _ in 0..<6 {
            do {
                try await sleep(.milliseconds(500))
            } catch {
                return .stillWorking
            }
            guard let snapshot = try? await client.snapshot() else { return .stopped }
            if snapshot.agents.first(where: { $0.paneID == paneID })?.status != .working { return .stopped }
        }
        return .stillWorking
    }

    /// 強制結束：送 `ctrl+c`,不確認結果(F6.7;呼叫端先請使用者確認)。
    public func forceQuit(paneID: String) async throws {
        try await client.sendKeys(paneID: paneID, keys: ["ctrl+c"])
    }
}
