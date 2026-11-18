import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Codex 的方案用量(#178):經主機通道執行 `codex app-server`,`initialize` 後呼叫 `account/rateLimits/read`。
/// 回應依 openai/codex `app-server-protocol` v2 的型別(camelCase、`usedPercent` 整數、`resetsAt` Unix 秒)手寫。
@Suite("Codex 方案用量(主機)")
struct CodexUsageHostTests {
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    /// 一個 bucket,5 小時與每週都有。
    static let singleBucket = #"""
        {"id":1,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1738425600},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1738857600},"credits":null,"planType":"plus"},"rateLimitsByLimitId":null}}
        """#

    static func appServer(answering rateLimits: String?, command: String = CodexUsageHost.command) async -> FakeHost {
        await FakeCodexAppServer.host(answering: rateLimits, command: command)
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

    static func read(_ rateLimits: String) async throws -> PlanUsage {
        try await CodexUsageHost(channel: await appServer(answering: rateLimits), now: { now }).readUsage()
    }

    @Test("只有每週(主要 bucket 是 10080 分鐘):依用量週期長度對應，只顯示每週")
    func weeklyOnly() async throws {
        let usage = try await Self.read(#"""
            {"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1738857600},"secondary":null}}}
            """#)

        #expect(usage.periods == [.init(kind: .week, usedPercentage: 30, resetsAt: Date(timeIntervalSince1970: 1_738_857_600))])
    }

    @Test("多 bucket:用 Codex 本身的那個(`rateLimitsByLimitId.codex`),不用其他 bucket")
    func multipleBuckets() async throws {
        let usage = try await Self.read(#"""
            {"id":1,"result":{"rateLimits":{"limitId":"codex_other","primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1738425600},"secondary":null},"rateLimitsByLimitId":{"codex_other":{"limitId":"codex_other","primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1738425600},"secondary":null},"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1738425600},"secondary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":1738857600}}}}}
            """#)

        #expect(usage.periods.map(\.kind) == [.fiveHour, .week])
        #expect(usage.periods.map(\.usedPercentage) == [12, 55])
    }

    @Test("超過 100%(Codex 會回報超過)夾在 0～100;缺 resetsAt 時沒有重置時間")
    func clampsAndMissingReset() async throws {
        let usage = try await Self.read(#"""
            {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":130,"windowDurationMins":300},"secondary":{"usedPercent":-5,"windowDurationMins":10080,"resetsAt":null}}}}
            """#)

        #expect(usage.periods == [
            .init(kind: .fiveHour, usedPercentage: 100, resetsAt: nil),
            .init(kind: .week, usedPercentage: 0, resetsAt: nil),
        ])
    }

    // MARK: - 錯誤

    @Test("主機找不到 codex(sh 回 127):codexNotFound")
    func codexNotFound() async throws {
        let host = FakeHost()
        await host.expect(CodexUsageHost.command, reply: FakeReply(stderr: Data("sh: codex: command not found\n".utf8), exitCode: 127))

        await #expect(throws: CodexUsageError.codexNotFound) {
            try await CodexUsageHost(channel: host).readUsage()
        }
    }

    @Test("主機找不到 codex,且 app 寫 stdin 前通道已結束(寫入失敗):仍是 codexNotFound,不是通道錯誤")
    func codexNotFoundBeforeWrite() async throws {
        await #expect(throws: CodexUsageError.codexNotFound) {
            try await CodexUsageHost(channel: ExitedBeforeWriteChannel(exitCode: 127)).readUsage()
        }
    }

    @Test("寫 stdin 前通道已結束、但不是 127:照原本的寫入錯誤")
    func otherExitBeforeWriteKeepsChannelError() async throws {
        await #expect(throws: ExitedBeforeWriteChannel.ChannelClosed.self) {
            try await CodexUsageHost(channel: ExitedBeforeWriteChannel(exitCode: 1)).readUsage()
        }
    }

    @Test("Codex 沒登入(或用 API key 登入，沒有方案用量):notSignedIn")
    func notSignedIn() async throws {
        for message in ["codex account authentication required to read rate limits", "chatgpt authentication required to read rate limits"] {
            await #expect(throws: CodexUsageError.notSignedIn) {
                try await Self.read(#"{"id":1,"error":{"code":-32600,"message":"\#(message)"}}"#)
            }
        }
    }

    @Test("app-server 查詢失敗(例如連不到 OpenAI):帶 app-server 的說明")
    func requestFailed() async throws {
        await #expect(throws: CodexUsageError.requestFailed("failed to fetch codex rate limits: timeout")) {
            try await Self.read(#"{"id":1,"error":{"code":-32603,"message":"failed to fetch codex rate limits: timeout"}}"#)
        }
    }

    @Test("回應無法解析(沒有 rateLimits、或還沒回應就結束):unreadableResponse")
    func unreadableResponse() async throws {
        await #expect(throws: CodexUsageError.unreadableResponse) {
            try await Self.read(#"{"id":1,"result":{"accountId":"a"}}"#)
        }
        let host = FakeHost()
        await host.expect(CodexUsageHost.command, reply: FakeReply(stdout: Data("not json\n".utf8), trigger: .afterStdinLine))
        await #expect(throws: CodexUsageError.unreadableResponse) {
            try await CodexUsageHost(channel: host).readUsage()
        }
    }

    @Test("app-server 一直不回應：沿用主機指令期限，逾時丟 deadlineExceeded 並關閉通道")
    func deadline() async throws {
        let host = FakeHost()
        await host.expect(CodexUsageHost.command, reply: FakeReply(trigger: .afterStdinLine, keepsOpen: true))

        await #expect(throws: HostCommandError.deadlineExceeded) {
            try await CodexUsageHost(channel: host, sleep: { _ in }).readUsage()
        }
        #expect(await host.waitUntilClosed(execution: 0))
    }

    @Test("Windows 主機：以 PowerShell 找 codex(找不到就 exit 127)後執行 app-server,stdin 原樣轉過去、不送 EOF")
    func windowsHost() async throws {
        let script = """
            $ProgressPreference='SilentlyContinue'
            $c=Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
            if(-not $c){[Console]::Error.Write("codex: command not found`n");exit 127}
            & $c.Source 'app-server'
            exit $LASTEXITCODE
            """
        let host = await Self.appServer(answering: Self.singleBucket, command: PowerShell.encodedCommand(script))

        let usage = try await CodexUsageHost(channel: WindowsHostChannel(host), now: { Self.now }).readUsage()

        #expect(usage.periods.map(\.kind) == [.fiveHour, .week])
        #expect(await host.executions.first?.closedStdin == false)
    }
}

/// 指令一開始就以 `exitCode` 結束的通道：之後寫 stdin 會失敗(像 SSH 通道已關閉)。
private struct ExitedBeforeWriteChannel: HostChannel {
    struct ChannelClosed: Error {}

    let exitCode: Int32

    func execute(_ command: String) async throws -> any ExecSession {
        let (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        continuation.yield(.stderr(Data("sh: codex: command not found
".utf8)))
        continuation.yield(.exit(code: exitCode))
        continuation.finish()
        return Session(output: output)
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { throw ChannelClosed() }

    struct Session: ExecSession {
        let output: AsyncThrowingStream<ExecOutput, any Error>
        func write(_ data: Data) async throws { throw ChannelClosed() }
        func closeStdin() async {}
        func close() async {}
    }
}
