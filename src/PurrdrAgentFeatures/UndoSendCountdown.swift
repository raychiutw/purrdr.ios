import Foundation
import Observation
import PurrdrCore

/// 送出可撤回的偏好(#300):秒數存在本機偏好，預設 3、範圍 0–10,0 為關閉。
public enum UndoSendSettings {
    /// `UserDefaults` key(設定頁與聊天輸入列讀同一個)。
    public static let secondsKey = "composer.undoSendSeconds"
    public static let defaultSeconds = 3
    public static let range = 0...10

    /// 限制在 0–10。
    public static func clamped(_ seconds: Int) -> Int {
        min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// 存著的秒數;沒存過是預設的 3 秒。
    public static func seconds(in defaults: UserDefaults) -> Int {
        clamped(defaults.object(forKey: secondsKey) as? Int ?? defaultSeconds)
    }
}

/// 送出管線的撤回倒數步驟(#300,spec #298):訊息先只在本機，倒數結束才交給下一步;
/// 期間可撤回(文字放回輸入框)或立即送出。秒數每次送出時讀(設定頁改了下一則就生效),0 直接通過。
///
/// 畫面以 `pending` 在對話最下面畫出虛線泡泡與「N 秒後送出 · 撤回 · 立即送出」。
@MainActor
@Observable
public final class UndoSendCountdown: SendStep {
    /// 倒數中的訊息。
    public struct Pending: Equatable, Sendable {
        public let text: String
        public var remainingSeconds: Int

        public init(text: String, remainingSeconds: Int) {
            self.text = text
            self.remainingSeconds = remainingSeconds
        }
    }

    /// 倒數中的訊息;沒有倒數時是 `nil`。
    public private(set) var pending: Pending?
    @ObservationIgnored private let seconds: @MainActor () -> Int
    @ObservationIgnored private let decision = UserDecision()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(seconds: @escaping @MainActor () -> Int) {
        self.seconds = seconds
    }

    public func process(_ prompt: OutgoingPrompt, clock: SendPipelineClock) async -> SendStepResult {
        let total = UndoSendSettings.clamped(seconds())
        // 同時只有一則倒數(輸入列送出中不能再送);萬一又來一則就不攔。
        guard total > 0, !decision.isWaiting else { return .proceed(prompt) }
        let sends = await decision.wait {
            pending = Pending(text: prompt.text, remainingSeconds: total)
            ticker = Task { [weak self, sleep = clock.sleep] in
                for _ in 0..<total {
                    do { try await sleep(.seconds(1)) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        }
        // 取消(離開聊天)時走到這裡:收掉倒數,不送出。
        clearCountdown()
        return sends ? .proceed(prompt) : .halt(SendHalt(restoresDraft: true))
    }

    /// 撤回：不送，文字放回輸入框。
    public func undo() { finish(sends: false) }

    /// 立即送出：不等倒數結束。
    public func sendNow() { finish(sends: true) }

    private func tick() {
        guard var current = pending else { return }
        current.remainingSeconds -= 1
        if current.remainingSeconds <= 0 {
            finish(sends: true)
        } else {
            pending = current
        }
    }

    private func finish(sends: Bool) {
        guard decision.isWaiting else { return }
        clearCountdown()
        decision.resolve(sends)
    }

    private func clearCountdown() {
        ticker?.cancel()
        ticker = nil
        pending = nil
    }
}
