import Foundation
import NIOCore
import PurrdrCore
import PurrdrTestSupport
import Synchronization
import Testing

/// Tailscale SSH check mode 經真 SSH 通道：對本機測試用 SSH 伺服器，伺服器依文件模擬 Tailscale 的行為
/// (先送認證橫幅帶驗證網址，不回覆認證結果，等使用者驗證完才放行)。
@Suite("Tailscale SSH check mode")
struct TailscaleCheckChannelTests {
    static let banner = Fixtures.tailscaleBanner("check-mode.banner.txt")
    static let url = URL(string: "https://login.tailscale.com/a/1a2b3c4d5e6f7")!

    @Test("要求重新驗證：回報驗證網址、等待期間不受握手期限限制，驗證完指令自動繼續", .timeLimit(.minutes(1)))
    func waitsForCheckThenRuns() async throws {
        // 期限由手動時鐘推進：機器忙(驗證網址晚到)也不會在網址送到前就逾時。
        let server = try await TestSSHServer.start(auth: { _ in
            .check(banner: Self.banner, bannerDelay: .milliseconds(1500), then: .approveOnRequest)
        }) {
            _ in .reply(stdout: "ok")
        }
        let prompts = PromptLog()
        let clock = ManualSSHClock()
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            timeouts: SSHTimeouts(handshake: .seconds(1)), tailscaleCheck: prompts.observe, scheduler: clock)

        let pending = Task { try await collect(channel.execute("x")) }
        _ = try await prompts.firstPrompt()
        // 等驗證時過了握手期限：仍套用握手期限的話這裡就會逾時。
        await clock.advance(by: .seconds(2))
        server.approveChecks()
        let result = try await pending.value

        #expect(result.stdout == "ok")
        #expect(prompts.urls == [Self.url, nil], "先顯示驗證網址，完成後收起")
        #expect(server.snapshot.connections == 1)
        #expect(server.snapshot.commands == ["x"])
        await channel.disconnect()
        await server.stop()
    }

    @Test("等待驗證期間可以取消：關掉連線、指令不送出，回報「已取消」", .timeLimit(.minutes(1)))
    func cancelWhileWaiting() async throws {
        let server = try await TestSSHServer.start(auth: { _ in .check(banner: Self.banner, then: .hold) }) { _ in .reply() }
        let prompts = PromptLog()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, tailscaleCheck: prompts.observe)

        let pending = Task { try await channel.execute("x") }
        let prompt = try await prompts.firstPrompt()
        #expect(prompt.url == Self.url)
        await prompt.cancel()

        await #expect(throws: SSHConnectionError.tailscaleCheckCancelled) { _ = try await pending.value }
        #expect(prompts.urls == [Self.url, nil])
        #expect(server.snapshot.commands.isEmpty)
        try await eventually { server.snapshot.disconnections == 1 }
        await server.stop()
    }

    @Test("等待驗證時連線斷了(例如 app 在背景被關掉 socket):自動重新撥號，驗證過後指令只送一次", .timeLimit(.minutes(1)))
    func redialsWhenDroppedWhileWaiting() async throws {
        let server = try await TestSSHServer.start(auth: { connection in
            connection == 1 ? .check(banner: Self.banner, then: .drop(after: .milliseconds(200))) : .accept
        }) { _ in .reply(stdout: "ok") }
        let prompts = PromptLog()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, tailscaleCheck: prompts.observe)

        let result = try await collect(channel.execute("x"))

        #expect(result.stdout == "ok")
        #expect(server.snapshot.connections == 2)
        #expect(server.snapshot.commands == ["x"])
        #expect(prompts.urls == [Self.url, nil])
        await channel.disconnect()
        await server.stop()
    }

    @Test("驗證被拒：回報登入失敗，不重撥", .timeLimit(.minutes(1)))
    func deniedAfterCheck() async throws {
        let server = try await TestSSHServer.start(auth: { _ in .check(banner: Self.banner, then: .deny(after: .milliseconds(100))) }) {
            _ in .reply()
        }
        let prompts = PromptLog()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, tailscaleCheck: prompts.observe)

        await #expect(throws: SSHConnectionError.authenticationFailed) { _ = try await channel.execute("x") }
        #expect(server.snapshot.connections == 1)
        #expect(prompts.urls == [Self.url, nil])
        await server.stop()
    }

    @Test("一直沒驗證：等到 check mode 的期限就結束，不會永遠等", .timeLimit(.minutes(1)))
    func checkTimesOut() async throws {
        let server = try await TestSSHServer.start(auth: { _ in .check(banner: Self.banner, then: .hold) }) { _ in .reply() }
        let prompts = PromptLog()
        let clock = ManualSSHClock()
        let channel = SSHHostChannel(
            endpoint: server.endpoint, hostKeyPin: server.fingerprint,
            timeouts: SSHTimeouts(handshake: .seconds(1), tailscaleCheck: .seconds(5)), tailscaleCheck: prompts.observe,
            scheduler: clock)

        let pending = Task { try await channel.execute("x") }
        _ = try await prompts.firstPrompt()
        await clock.advance(by: .seconds(5))

        await #expect(throws: SSHConnectionError.tailscaleCheckTimedOut) { _ = try await pending.value }
        #expect(server.snapshot.connections == 1)
        #expect(prompts.urls == [Self.url, nil])
        try await eventually { server.snapshot.disconnections == 1 }
        await server.stop()
    }

    @Test("沒有 check mode 的一般登入：不回報任何提示")
    func noPromptWithoutCheck() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "ok") }
        let prompts = PromptLog()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, tailscaleCheck: prompts.observe)

        _ = try await collect(channel.execute("x"))

        #expect(prompts.urls.isEmpty)
        await channel.disconnect()
        await server.stop()
    }
}

/// 輪詢到條件成立(上限 `asyncWaitLimit`;條件一成立就返回)。
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + asyncWaitLimit
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("等不到條件成立", sourceLocation: sourceLocation)
}

/// 記錄主機通道回報的 check mode 提示(`nil` = 收起)。
final class PromptLog: Sendable {
    private let state = Mutex<[TailscaleCheckPrompt?]>([])

    var prompts: [TailscaleCheckPrompt?] { state.withLock { $0 } }
    var urls: [URL?] { prompts.map { $0?.url } }

    var observe: TailscaleCheckObserver {
        { prompt in self.state.withLock { $0.append(prompt) } }
    }

    /// 等到出現第一個提示。
    func firstPrompt() async throws -> TailscaleCheckPrompt {
        let deadline = ContinuousClock.now + asyncWaitLimit
        while ContinuousClock.now < deadline {
            if let prompt = prompts.compactMap({ $0 }).first { return prompt }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PromptLogError.noPrompt
    }
}

enum PromptLogError: Error {
    case noPrompt
}
