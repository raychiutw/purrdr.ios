import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Codex 的方案用量(#178):經主機通道執行 `codex app-server`,`initialize` 後呼叫 `account/rateLimits/read`。
/// 回應依 openai/codex `app-server-protocol` v2 的型別(camelCase、`usedPercent` 整數、`resetsAt` Unix 秒)手寫。
@Suite("Codex 方案用量(主機)")
struct CodexUsageHostTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)
    static let initializeResponse = #"{"id":0,"result":{"userAgent":"codex_cli_rs/0.80.0"}}"#

    /// 一個 bucket,5 小時與每週都有。
    static let singleBucket = #"""
        {"id":1,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1738425600},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1738857600},"credits":null,"planType":"plus"},"rateLimitsByLimitId":null}}
        """#

    /// 假的 app-server:收到 `initialize` 那一行就回 `initialize` 的回應，收到讀取請求後回 `rateLimits`。
    static func appServer(answering rateLimits: String?, initialize: String = initializeResponse) async -> FakeHost {
        let host = FakeHost()
        await host.expect(
            CodexUsageHost.command, reply: FakeReply(stdout: Data((initialize + "\n").utf8), trigger: .afterStdinLine, keepsOpen: true))
        if let rateLimits {
            Task {
                guard await host.waitForStdin(ofExecution: 0, until: { $0.stdinText.contains("account/rateLimits/read") }) else { return }
                await host.send(stdout: Data((rateLimits + "\n").utf8), toExecution: 0)
            }
        }
        return host
    }

    static func methods(in stdin: String) -> [String] {
        stdin.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String
        }
    }

    @Test("一個 bucket:5 小時與每週各一個用量週期，重置時間是 Unix 秒，擷取時間是查詢當下;讀完就結束子程序")
    func singleBucket() async throws {
        let host = await Self.appServer(answering: Self.singleBucket)

        let usage = try await CodexUsageHost(channel: host, now: { Self.now }).readUsage()

        #expect(usage == PlanUsage(periods: [
            .init(kind: .fiveHour, usedPercentage: 23, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
            .init(kind: .week, usedPercentage: 41, resetsAt: Date(timeIntervalSince1970: 1_738_857_600)),
        ], capturedAt: Self.now))
        let execution = try #require(await host.executions.first)
        #expect(Self.methods(in: execution.stdinText) == ["initialize", "initialized", "account/rateLimits/read"])
        #expect(await host.waitUntilClosed(execution: 0))
    }
}
