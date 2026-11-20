import Foundation
import Observation
import PurrdrCore

/// 一次等使用者決定的機密偵測結果(畫面依它開說明 sheet)。只有類別與行號，不帶內容。
public struct SecretReview: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let findings: [SecretFinding]

    public init(id: UUID = UUID(), findings: [SecretFinding]) {
        self.id = id
        self.findings = findings
    }
}

/// 送出管線的機密偵測步驟(#302,spec #298;放在管線最前面)。
///
/// 以 `SecretDetection` 在本機掃描要送出的文字;沒有偵測到就原樣通過。偵測到時設定 `review`(畫面開 sheet)並等使用者決定：
/// 「返回編輯」擋下送出、文字放回輸入框;「仍要送出」原樣交給下一步。決定之前什麼都不會送到主機。
@MainActor
@Observable
public final class SecretCheck: SendStep {
    /// 等使用者決定的偵測結果;沒有時是 `nil`。
    public private(set) var review: SecretReview?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?

    public init() {}

    public func process(_ prompt: OutgoingPrompt, clock: SendPipelineClock) async -> SendStepResult {
        let findings = SecretDetection.scan(prompt.text)
        if findings.isEmpty { return .proceed(prompt) }
        if Task.isCancelled { return .halt(SendHalt(restoresDraft: true)) }
        // 上一則還沒決定就又送出(理論上 sheet 開著時送不出):舊的當作返回編輯。
        decide(sendAnyway: false)
        let next = SecretReview(findings: findings)
        let sendAnyway = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision = continuation
                review = next
            }
        } onCancel: {
            // 離開聊天(送出的 task 被取消):當作返回編輯;只收掉自己這一次。
            Task { @MainActor in
                if self.review?.id == next.id { self.decide(sendAnyway: false) }
            }
        }
        return sendAnyway ? .proceed(prompt) : .halt(SendHalt(restoresDraft: true))
    }

    /// 「返回編輯」(主要動作;sheet 被下滑關閉也是)。
    public func returnToEditing() {
        decide(sendAnyway: false)
    }

    /// 「仍要送出」。
    public func sendAnyway() {
        decide(sendAnyway: true)
    }

    private func decide(sendAnyway: Bool) {
        review = nil
        let pending = decision
        decision = nil
        pending?.resume(returning: sendAnyway)
    }
}
