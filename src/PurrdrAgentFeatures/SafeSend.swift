import Foundation
import PurrdrCore

/// 安全送出(#558):把一段 prompt 交給某個 pane 的「送前確認 + 送出 + 結果分類」收在一處。
///
/// 流程:重讀**新鮮的** snapshot 確認 pane 還在、session 沒換(2 秒前的 pane 可能已被回收成另一個聊天,R-P06)
/// → 交給 `PromptDelivery`(HTTPS 主機另在送出前比對 session)→ 回傳型別化結果。
/// 聊天的送出、重試、`/model` 與 `/effort`,以及離線佇列的補送都經這裡,不各自再確認一次。
///
/// 結果自己說明「有沒有送出任何東西」(`Result.sentNothing`):呼叫端據此決定草稿與附件;
/// 什麼都沒送出 ⇔ 草稿與附件都要保留,不必看畫面提示。
///
/// **離線佇列的兩條餵入路徑**:佇列只在重連後收到的第一份 Agent 列表比對一次(`OfflineQueue.receive(_:)`),
/// 這份列表來自 (1) 主機更新來源(`HostUpdates.onSnapshot`)或 (2) 聊天自己讀到的快照。比對通過才補送,
/// 補送時再經這裡重讀一次新鮮快照確認(列表可能已是幾秒前的)。
public struct SafeSend: Sendable {
    /// 要送給哪個 pane。
    public struct Destination: Sendable, Equatable {
        public var paneID: String
        /// app 看到的 session;主機回報的 session 與它不同就不送。`nil` 不擋。
        public var expectedSession: String?
        /// 讀不到新鮮快照時退回使用的 Agent(輪詢得到的那份)。
        public var fallback: Agent?

        public init(paneID: String, expectedSession: String?, fallback: Agent? = nil) {
            self.paneID = paneID
            self.expectedSession = expectedSession
            self.fallback = fallback
        }
    }

    /// 什麼都沒送出的原因。
    public enum NotSent: Error, Sendable, Equatable {
        /// 這個 pane 已經沒有 agent。
        case agentGone
        /// pane 被回收成另一個聊天(session 換了,或主機送出前比對發現對話已變更)。
        case conversationChanged
        /// agent 正在等一個問題;帶送出當下讀到的 Agent,呼叫端據此立刻找出問題。
        case needsAnswer(Agent)
        /// herdr 拒絕(原文)。
        case rejected(String)
        /// 這支裝置配對成唯讀。
        case readOnlyDevice
    }

    public enum Result: Sendable, Equatable {
        case delivered
        /// Slash 指令或 `!` 指令已交給主機(不等待、不確認)。
        case submittedCommand
        /// agent 沒接住(停滯);文字可能還在 agent 的輸入框裡。
        case noResponse
        /// 不知道有沒有送到:**不可自動重送**(§7.3)。
        case unconfirmed(UnconfirmedReason)
        case notSent(NotSent)

        /// 主機什麼都沒收到:呼叫端放回草稿、保留附件。其餘結果(含不確定)都視為可能已送出。
        public var sentNothing: Bool {
            if case .notSent = self { return true }
            return false
        }

        init(_ outcome: PromptOutcome, agent: Agent) {
            switch outcome {
            case .delivered: self = .delivered
            case .submittedCommand: self = .submittedCommand
            case .noResponse: self = .noResponse
            case .unconfirmed(let reason): self = .unconfirmed(reason)
            case .needsAnswer: self = .notSent(.needsAnswer(agent))
            case .rejected(let message): self = .notSent(.rejected(message))
            case .readOnlyDevice: self = .notSent(.readOnlyDevice)
            case .paneChanged: self = .notSent(.conversationChanged)
            }
        }
    }

    private let client: HerdrClient
    private let delivery: PromptDelivery

    public init(client: HerdrClient, sleep: @escaping Sleep = Sleeping.task) {
        self.client = client
        delivery = PromptDelivery(client: client, sleep: sleep)
    }

    /// 確認目標後送出 `text`。
    public func send(_ text: String, to destination: Destination) async -> Result {
        let agent: Agent
        switch await freshAgent(for: destination) {
        case .success(let found): agent = found
        case .failure(let reason): return .notSent(reason)
        }
        return Result(await delivery.send(text, to: agent, expectedSession: destination.expectedSession), agent: agent)
    }

    private func freshAgent(for destination: Destination) async -> Swift.Result<Agent, NotSent> {
        let agent: Agent?
        if let snapshot = try? await client.snapshot() {
            agent = snapshot.agents.first { $0.paneID == destination.paneID }
        } else {
            agent = destination.fallback
        }
        guard let agent else { return .failure(.agentGone) }
        if let expected = destination.expectedSession, let session = agent.sessionID, session != expected {
            return .failure(.conversationChanged)
        }
        return .success(agent)
    }
}
