import Foundation

/// 一個操作花了多久(#635):新增聊天／續接的各步驟、SSH 開通道與 herdr 請求。只有名稱、毫秒數與成敗，不含任何內容。
public struct OperationTiming: Sendable, Equatable {
    /// 操作名稱，例如 `resume.createTab`、`ssh.open agent.start`。
    public var name: String
    public var milliseconds: Int
    public var failed: Bool
    public var at: Date

    public init(name: String, milliseconds: Int, failed: Bool = false, at: Date) {
        self.name = name
        self.milliseconds = milliseconds
        self.failed = failed
        self.at = at
    }
}

/// 計時的出口(診斷記錄;沒接時不記)。可能從任何執行緒呼叫。
public typealias OperationTimingSink = @Sendable (OperationTiming) -> Void

/// 量一段非同步工作，結束(成功或丟錯)時交給 `sink`。`sink` 為 `nil` 時只執行工作。
public enum OperationTimer {
    /// `isolation`:在呼叫端的隔離區執行 `body`(actor 內的步驟不必是 Sendable)。
    public static func measure<T>(
        _ name: String, sink: OperationTimingSink?, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T
    ) async throws -> T {
        guard let sink else { return try await body() }
        let clock = ContinuousClock()
        let start = clock.now
        let begunAt = Date()
        func report(failed: Bool) {
            let elapsed = clock.now - start
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            sink(OperationTiming(name: name, milliseconds: milliseconds, failed: failed, at: begunAt))
        }
        do {
            let value = try await body()
            report(failed: false)
            return value
        } catch {
            report(failed: true)
            throw error
        }
    }
}
