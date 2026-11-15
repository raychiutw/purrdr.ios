import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

@Suite("連線測試(儲存主機前)")
struct HostProbeTests {
    static let herdr = HerdrInstallation()

    static func healthyHost() async -> FakeHost {
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Darwin\n".utf8)))
        await host.expect(HerdrCommand.version(herdr), reply: FakeReply(stdout: Data("herdr 0.9.5\n".utf8)))
        await host.expect(HerdrCommand.bridge(herdr), reply: .recorded("ping.ndjson"))
        await host.expect(HerdrCommand.bridge(herdr), reply: .recorded("session.snapshot.ndjson"))
        await host.expect(HerdrCommand.bridge(herdr), reply: .recorded("integration.list.ndjson"))
        return host
    }

    @Test("偵測主機 OS、herdr 伺服器版本、Agent 數與已安裝的 agent 整合")
    func reportsHostDetails() async throws {
        let host = await Self.healthyHost()

        let report = try await HostProbe(channel: host, herdr: Self.herdr).run()

        #expect(report.operatingSystem == .macOS)
        #expect(report.herdrVersion == HerdrVersion("0.9.5"))
        #expect(report.agentCount == 3)
        // 只列出主機上有那個 agent 指令的整合(錄製檔:claude、copilot、hermes)。
        #expect(report.integrations == [
            AgentIntegration(target: "claude", label: "claude", state: .current),
            AgentIntegration(target: "copilot", label: "copilot", state: .outdated),
            AgentIntegration(target: "hermes", label: "hermes", state: .current),
        ])
        let methods = await host.executions.filter { $0.command == HerdrCommand.bridge(Self.herdr) }.map(\.stdinText)
        #expect(methods == [
            #"{"id":"purrdr:ping","method":"ping","params":{}}"# + "\n",
            #"{"id":"purrdr:session.snapshot","method":"session.snapshot","params":{}}"# + "\n",
            #"{"id":"purrdr:integration.list","method":"integration.list","params":{}}"# + "\n",
        ])
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("找不到 herdr(exit 127):回報未安裝，不再往下問")
    func herdrNotInstalled() async {
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Linux\n".utf8)))
        await host.expect(HerdrCommand.version(Self.herdr), reply: FakeReply(stderr: Data("sh: 1: herdr: not found\n".utf8), exitCode: 127))

        await #expect(throws: HostProbeError.herdrNotInstalled) {
            _ = try await HostProbe(channel: host, herdr: Self.herdr).run()
        }
    }

    @Test("安裝的 herdr 低於 0.9.5:回報版本，等使用者確認才更新")
    func installedHerdrTooOld() async {
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Darwin\n".utf8)))
        await host.expect(HerdrCommand.version(Self.herdr), reply: FakeReply(stdout: Data("herdr 0.9.3\n".utf8)))

        await #expect(throws: HostProbeError.herdrOutdated(HerdrVersion("0.9.3")!)) {
            _ = try await HostProbe(channel: host, herdr: Self.herdr).run()
        }
        #expect(await host.executions.map(\.command) == [HerdrCommand.operatingSystem, HerdrCommand.version(Self.herdr)])
    }

    @Test("這個 session 沒有在跑 herdr:bridge 連不到 socket")
    func serverNotRunning() async {
        let herdr = HerdrInstallation(session: "work")
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Darwin\n".utf8)))
        await host.expect(HerdrCommand.version(herdr), reply: FakeReply(stdout: Data("herdr 0.9.5\n".utf8)))
        // 真實主機 herdr 0.9.5 在 session 沒有伺服器時的輸出(路徑換成假值)。
        let stderr = #"Error: Custom { kind: NotFound, error: "failed to connect to remote Herdr API socket /Users/demo/.config/herdr/sessions/work/herdr.sock: No such file or directory (os error 2)" }"# + "\n"
        await host.expect(HerdrCommand.bridge(herdr), reply: FakeReply(stderr: Data(stderr.utf8), exitCode: 1, trigger: .afterStdinLine))

        await #expect(throws: HostProbeError.serverNotRunning) {
            _ = try await HostProbe(channel: host, herdr: herdr).run()
        }
    }

    @Test("確認後更新 herdr:執行 update --handoff")
    func updatesHerdr() async throws {
        let host = FakeHost()
        await host.expect(HerdrCommand.update(Self.herdr), reply: FakeReply(stdout: Data("updated\n".utf8)))

        try await HostProbe(channel: host, herdr: Self.herdr).updateHerdr()

        #expect(await host.executions.map(\.command) == [HerdrCommand.update(Self.herdr)])
    }

    @Test("更新失敗時帶回主機的錯誤訊息")
    func updateFailure() async {
        let host = FakeHost()
        await host.expect(HerdrCommand.update(Self.herdr), reply: FakeReply(stderr: Data("network unreachable\n".utf8), exitCode: 1))

        await #expect(throws: HostProbeError.updateFailed("network unreachable")) {
            try await HostProbe(channel: host, herdr: Self.herdr).updateHerdr()
        }
    }
}

@Suite("herdr 版本")
struct HerdrVersionTests {
    @Test("以數值比較，不是字串比較(0.10.0 > 0.9.5)")
    func numericComparison() throws {
        #expect(try #require(HerdrVersion("0.10.0")) > #require(HerdrVersion("0.9.5")))
        #expect(try #require(HerdrVersion("0.9.4")) < HerdrVersion.minimumSupported)
        #expect(HerdrVersion("0.9.5") == HerdrVersion.minimumSupported)
    }

    @Test("容忍前導 v、herdr 前綴與 build 尾碼;無法解析就是 nil")
    func lenientParsing() {
        #expect(HerdrVersion("v0.9.6-beta.2") == HerdrVersion("0.9.6"))
        #expect(HerdrVersion("herdr 0.9.5\n") == HerdrVersion("0.9.5"))
        #expect(HerdrVersion("usage: herdr-core") == nil)
    }
}
