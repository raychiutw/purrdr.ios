import Foundation
import PurrdrCore

/// 送出管線給步驟的環境(測試注入):現在時間、等待,以及**此刻**連不連得上主機。
/// 撤回倒數、離線佇列的過期判斷用時鐘;離線佇列在輪到它時才問連線狀態(倒數期間連線可能變了)。
public struct SendPipelineClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: Sleep
    /// 此刻連得上主機嗎;不是送出當下的快照,步驟輪到時才呼叫。
    public var isHostReachable: @MainActor @Sendable () -> Bool

    public init(
        now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping Sleep = Sleeping.task,
        isHostReachable: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.now = now
        self.sleep = sleep
        self.isHostReachable = isHostReachable
    }
}

/// 要送給 Agent 的一則訊息(還在本機，經過管線的步驟後才交給主機)。
public struct OutgoingPrompt: Sendable, Equatable {
    /// 要送出的文字(已去掉前後空白;圖片路徑在交給主機時才加上)。
    public var text: String
    /// 對象的 pane。
    public let paneID: String
    /// 送出時預期的 session:對象的 session 換了就不是同一個聊天(F5.1)。
    public let expectedSession: String?
    /// 按下送出的時間。
    public let createdAt: Date
    /// 對象所在的 Workspace(離線佇列重連後比對 pane 沒變,#301);不知道時是 `nil`。
    public let workspaceID: String?

    public init(
        text: String, paneID: String, expectedSession: String?, createdAt: Date,
        workspaceID: String? = nil
    ) {
        self.text = text
        self.paneID = paneID
        self.expectedSession = expectedSession
        self.createdAt = createdAt
        self.workspaceID = workspaceID
    }
}

/// 步驟擋下送出。
public struct SendHalt: Sendable, Equatable {
    /// 文字放回輸入框(撤回、機密偵測取消);`false` 表示步驟接手了這則訊息(例如排進離線佇列),輸入框維持清空。
    public var restoresDraft: Bool

    public init(restoresDraft: Bool) {
        self.restoresDraft = restoresDraft
    }
}

/// 一個步驟的結果。
public enum SendStepResult: Sendable, Equatable {
    /// 交給下一步(可改過內容)。
    case proceed(OutgoingPrompt)
    /// 不再往下送。
    case halt(SendHalt)
}

/// 送出管線的一個步驟(機密偵測、撤回倒數、離線佇列…)。
@MainActor
public protocol SendStep {
    func process(_ prompt: OutgoingPrompt, clock: SendPipelineClock) async -> SendStepResult
}

/// 以 closure 實作的步驟。
@MainActor
public struct SendStepClosure: SendStep {
    private let body: @MainActor (OutgoingPrompt, SendPipelineClock) async -> SendStepResult

    public init(_ body: @escaping @MainActor (OutgoingPrompt, SendPipelineClock) async -> SendStepResult) {
        self.body = body
    }

    public func process(_ prompt: OutgoingPrompt, clock: SendPipelineClock) async -> SendStepResult {
        await body(prompt, clock)
    }
}

/// 聊天的送出管線有哪些步驟(#566):各步驟以具名欄位給,畫面直接拿到它們,管線不必以型別取回。
/// 順序固定:機密偵測、Send When Done、撤回倒數、離線佇列,最後才是 `custom`(測試或其他步驟)。
@MainActor
public struct SendStages {
    public var secretCheck: SecretCheck?
    public var sendWhenDone: SendWhenDoneStep?
    public var undo: UndoSendCountdown?
    public var offlineQueue: OfflineQueueStep?
    public var custom: [any SendStep]

    public init(
        secretCheck: SecretCheck? = nil, sendWhenDone: SendWhenDoneStep? = nil, undo: UndoSendCountdown? = nil,
        offlineQueue: OfflineQueueStep? = nil, custom: [any SendStep] = []
    ) {
        self.secretCheck = secretCheck
        self.sendWhenDone = sendWhenDone
        self.undo = undo
        self.offlineQueue = offlineQueue
        self.custom = custom
    }

    /// 依固定順序排好的步驟。
    var steps: [any SendStep] {
        var all: [any SendStep] = []
        if let secretCheck { all.append(secretCheck) }
        if let sendWhenDone { all.append(sendWhenDone) }
        if let undo { all.append(undo) }
        if let offlineQueue { all.append(offlineQueue) }
        return all + custom
    }
}

/// 送出管線(#299,spec #298):依序跑步驟，全部通過後由呼叫端交給主機。
/// 聊天輸入列與 Send When Done 共用;步驟與時鐘都由建立者注入。
@MainActor
public struct SendPipeline {
    public let steps: [any SendStep]
    public let clock: SendPipelineClock

    public init(steps: [any SendStep] = [], clock: SendPipelineClock = SendPipelineClock()) {
        self.steps = steps
        self.clock = clock
    }

    /// 依序跑步驟;有步驟擋下就停，後面的不跑。`isHostReachable` 給步驟輪到時查連線狀態(離線佇列在倒數結束時才判斷)。
    public func prepare(_ prompt: OutgoingPrompt, isHostReachable: @escaping @MainActor @Sendable () -> Bool = { true }) async -> SendStepResult {
        var current = prompt
        var stepClock = clock
        stepClock.isHostReachable = isHostReachable
        for step in steps {
            switch await step.process(current, clock: stepClock) {
            case .proceed(let next): current = next
            case .halt(let halt): return .halt(halt)
            }
        }
        return .proceed(current)
    }
}

/// 管線步驟「等使用者決定」的共用機制(撤回倒數、機密偵測):等到有人 `resolve`;
/// 等的 task 被取消(離開聊天)就當作「不送」,只收掉自己這一次。
@MainActor
final class UserDecision {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var generation = 0

    var isWaiting: Bool { continuation != nil }

    /// 登記後呼叫 `start`(設定畫面狀態),等結果;`true` 是照送。
    func wait(start: () -> Void) async -> Bool {
        generation += 1
        let mine = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in
                if self.generation == mine { self.resolve(false) }
            }
        }
    }

    func resolve(_ sends: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(returning: sends)
    }
}
