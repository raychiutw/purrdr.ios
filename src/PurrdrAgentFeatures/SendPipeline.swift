import Foundation
import PurrdrCore

/// 送出管線的時鐘(測試注入):現在時間與等待。撤回倒數、離線佇列的過期判斷都用它。
public struct SendPipelineClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: Sleep

    public init(now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping Sleep = Sleeping.task) {
        self.now = now
        self.sleep = sleep
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
    /// 按下送出時連得上主機;`false` 時離線佇列接手(#301)。
    public let isHostReachable: Bool

    public init(
        text: String, paneID: String, expectedSession: String?, createdAt: Date,
        workspaceID: String? = nil, isHostReachable: Bool = true
    ) {
        self.text = text
        self.paneID = paneID
        self.expectedSession = expectedSession
        self.createdAt = createdAt
        self.workspaceID = workspaceID
        self.isHostReachable = isHostReachable
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

    /// 依序跑步驟;有步驟擋下就停，後面的不跑。
    public func prepare(_ prompt: OutgoingPrompt) async -> SendStepResult {
        var current = prompt
        for step in steps {
            switch await step.process(current, clock: clock) {
            case .proceed(let next): current = next
            case .halt(let halt): return .halt(halt)
            }
        }
        return .proceed(current)
    }
}
