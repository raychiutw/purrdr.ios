import Foundation
import PurrdrCore
import PurrdrSSH

/// 假的 `codex app-server`(#178):收到 `initialize` 那一行就回它的回應，收到 `account/rateLimits/read` 後回 `rateLimits`。
/// `rateLimits` 是 `nil` 時只回 `initialize`。
public enum FakeCodexAppServer {
    public static let initializeResponse = #"{"id":0,"result":{"userAgent":"codex_cli_rs/0.80.0"}}"#

    public static func host(
        answering rateLimits: String?, initialize: String = initializeResponse, command: String = CodexPlanUsageHost.command
    ) async -> FakeHost {
        let host = FakeHost()
        await host.expect(
            command, reply: FakeReply(stdout: Data((initialize + "\n").utf8), trigger: .afterStdinLine, keepsOpen: true))
        if let rateLimits {
            Task {
                guard await host.waitForStdin(ofExecution: 0, until: { $0.stdinText.contains("account/rateLimits/read") }) else { return }
                await host.send(stdout: Data((rateLimits + "\n").utf8), toExecution: 0)
            }
        }
        return host
    }
}
