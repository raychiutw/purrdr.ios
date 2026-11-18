import Foundation
import PurrdrCore

/// 查不到 Codex 方案用量的原因。
public enum CodexUsageError: Error, Equatable {
    case unreadableResponse
}

/// Codex 的方案用量(#178):執行一次 `codex app-server`,讀 `account/rateLimits/read`。
public struct CodexUsageHost: Sendable {
    public static let command = "\(HerdrCommand.pathPrefix) codex app-server"

    private let channel: any HostChannel
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    public init(channel: any HostChannel, now: @escaping @Sendable () -> Date = Date.init, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.now = now
        self.sleep = sleep
    }

    public func readUsage() async throws -> PlanUsage {
        throw CodexUsageError.unreadableResponse
    }
}
