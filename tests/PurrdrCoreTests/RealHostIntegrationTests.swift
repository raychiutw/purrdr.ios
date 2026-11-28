import Foundation
import NIOSSH
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 對真實主機的整合測試，以環境變數開啟(預設不跑;CI 不跑)。只執行唯讀指令。
///
/// ```bash
/// # 經 Tailscale SSH 連真的主機(要在另一台裝置上跑：Tailscale SSH 不接受同一台機器連自己的 tailnet IP)
/// PURRDR_REAL_HOST=demo@my-mac swift test --filter RealHostIntegrationTests
/// # 可選:PURRDR_REAL_HOST_FINGERPRINT=SHA256:…(主機上 `ssh-keygen -lf` 的結果),比對 TOFU 回報的指紋
/// # 可選:PURRDR_REAL_HOST_SESSION=<具名 session>、PURRDR_REAL_HOST_HERDR=<herdr 路徑>
///
/// # 本機的真 herdr,經測試用 SSH 伺服器(swift-nio-ssh server)以 /bin/sh 執行
/// PURRDR_LOCAL_HERDR=1 swift test --filter RealHostIntegrationTests
/// ```
@Suite("真實主機整合測試")
struct RealHostIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test("經 Tailscale SSH:先回報指紋(TOFU),pin 之後連線測試讀到 herdr ≥ 0.9.5 與 snapshot",
          .enabled(if: environment["PURRDR_REAL_HOST"] != nil))
    func tailscaleSSHHost() async throws {
        let environment = Self.environment
        let endpoint = try #require(Self.endpoint(environment["PURRDR_REAL_HOST"] ?? ""), "PURRDR_REAL_HOST 要是 user@host[:port]")
        let herdr = HerdrInstallation(path: environment["PURRDR_REAL_HOST_HERDR"] ?? "", session: environment["PURRDR_REAL_HOST_SESSION"])

        let first = SSHHostChannel(endpoint: endpoint, hostKeyPin: nil)
        var presented: HostKeyFingerprint?
        do {
            _ = try await first.execute("true")
            Issue.record("沒有 pin 卻登入了")
        } catch SSHConnectionError.hostKeyUnverified(let fingerprint) {
            presented = fingerprint
        }
        let pin = try #require(presented)
        if let expected = environment["PURRDR_REAL_HOST_FINGERPRINT"] {
            #expect(pin == HostKeyFingerprint(stored: expected), "指紋與 ssh-keygen -lf 不同")
        }
        print("主機指紋:\(pin)")

        let channel = SSHHostChannel(endpoint: endpoint, hostKeyPin: pin)
        let report = try await HostProbe(channel: channel, herdr: herdr).run()
        #expect(report.herdrVersion >= .minimumSupported)
        let snapshot = try await HerdrClient(channel: channel, herdr: herdr).snapshot()
        print("herdr \(report.herdrVersion) · \(report.operatingSystem) · \(snapshot.agents.count) agents · 整合 \(report.integrations.map(\.target))")
        #expect(snapshot.agents.count == report.agentCount)
        await channel.disconnect()
    }

    @Test("本機真 herdr 經 SSH:連線測試與 snapshot 走真的 swift-nio-ssh 與 remote-api-bridge",
          .enabled(if: environment["PURRDR_LOCAL_HERDR"] != nil))
    func localHerdrOverSSH() async throws {
        // `.runLocally` 會以開發者身分跑 /bin/sh,所以用 ssh-keygen 產生的暫時金鑰、只放行這把公鑰(#695)。
        let generated = try SSHKeygen.generate(type: "ed25519")
        defer { generated.remove() }
        let key = try SSHPrivateKey(openSSH: generated.privateText)
        let authorized = try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyWithoutComment)
        let server = try await TestSSHServer.start(authentication: .publicKeys([authorized])) { _ in .runLocally }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .privateKey(key) }
        let herdr = HerdrInstallation()

        let report = try await HostProbe(channel: channel, herdr: herdr).run()
        #expect(report.herdrVersion >= .minimumSupported)
        let snapshot = try await HerdrClient(channel: channel, herdr: herdr).snapshot()
        print("herdr \(report.herdrVersion) · \(report.operatingSystem) · \(snapshot.agents.count) agents · 整合 \(report.integrations.map(\.target))")
        #expect(snapshot.agents.count == report.agentCount)
        #expect(server.snapshot.connections == 1, "連線沒有重用")
        await channel.disconnect()
    }

    /// 只在自建的 `~/purrdr-166-it-<uuid>` 裡讀寫，結束時刪掉。
    @Test("經 Tailscale SSH:長駐追蹤腳本讀到新增;斷線與停止追蹤後主機上都沒有留下追蹤腳本(#166)",
          .enabled(if: environment["PURRDR_REAL_HOST"] != nil))
    func transcriptFollowerLeavesNoProcess() async throws {
        let endpoint = try #require(Self.endpoint(Self.environment["PURRDR_REAL_HOST"] ?? ""))
        let pin = try #require(await Self.presentedFingerprint(endpoint))
        let folder = "purrdr-166-it-\(UUID().uuidString)"
        let helper = SSHHostChannel(endpoint: endpoint, hostKeyPin: pin)
        let home = try await Self.run("printf '%s' \"$HOME\"", on: helper)
        let path = "\(home)/\(folder)/session.jsonl"
        _ = try await Self.run("mkdir -p ~/\(folder) && printf '%s\\n' '{\"n\":1}' > ~/\(folder)/session.jsonl", on: helper)

        // 呼叫端不再讀：關閉通道，腳本讀到 EOF 結束。
        let stopping = SSHHostChannel(endpoint: endpoint, hostKeyPin: pin)
        let stoppingPace = TranscriptFollowPace(interval: .seconds(3600))
        var stoppingEvents: AsyncThrowingStream<TranscriptFollowEvent, any Error>.AsyncIterator? =
            await SSHHostConnection(channel: stopping).followTranscript(path: path, from: 8, pace: stoppingPace).makeAsyncIterator()
        _ = try await Self.run("printf '%s\\n' '{\"n\":2}' >> ~/\(folder)/session.jsonl", on: helper)
        stoppingPace.wake()
        #expect(try await stoppingEvents?.next() == .appended(TranscriptChunk(start: 8, end: 16, lines: [#"{"n":2}"#])))
        let whileFollowing = try await Self.followerProcesses(on: helper)
        stoppingEvents = nil
        try await Task.sleep(for: .seconds(3))
        let afterStop = try await Self.followerProcesses(on: helper)
        await stopping.disconnect()

        // 斷線(像 app 被殺)時 sshd 關掉通道，腳本同樣結束。
        let dropping = SSHHostChannel(endpoint: endpoint, hostKeyPin: pin)
        let droppingPace = TranscriptFollowPace(interval: .seconds(3600))
        var droppingEvents = await SSHHostConnection(channel: dropping).followTranscript(path: path, from: 16, pace: droppingPace).makeAsyncIterator()
        _ = try await Self.run("printf '%s\\n' '{\"n\":3}' >> ~/\(folder)/session.jsonl", on: helper)
        droppingPace.wake()
        #expect(try await droppingEvents.next() == .appended(TranscriptChunk(start: 16, end: 24, lines: [#"{"n":3}"#])))
        await dropping.disconnect()
        try await Task.sleep(for: .seconds(3))
        let afterDisconnect = try await Self.followerProcesses(on: helper)

        _ = try await Self.run("rm -rf ~/\(folder)", on: helper)
        await helper.disconnect()
        #expect(whileFollowing != "", "追蹤中主機上應有腳本(確認檢查方式有效)")
        #expect(afterStop == "", "停止追蹤後還有追蹤腳本:\(afterStop)")
        #expect(afterDisconnect == "", "斷線後還有追蹤腳本:\(afterDisconnect)")
    }

    /// 主機上的追蹤腳本(`purrdr_anchor` 是它獨有的函式名;pattern 寫成 `[r]` 不比對到 grep 自己)。
    static func followerProcesses(on channel: SSHHostChannel) async throws -> String {
        try await run("ps -A -ww -o pid=,command= | grep 'purrdr_ancho[r]' || true", on: channel)
    }

    static func run(_ command: String, on channel: SSHHostChannel) async throws -> String {
        let session = try await channel.execute(command)
        await session.closeStdin()
        let output = try await session.collectOutput()
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 第一次連線(沒有 pin)時主機出示的指紋(TOFU)。
    static func presentedFingerprint(_ endpoint: SSHEndpoint) async throws -> HostKeyFingerprint? {
        do {
            _ = try await SSHHostChannel(endpoint: endpoint, hostKeyPin: nil).execute("true")
        } catch SSHConnectionError.hostKeyUnverified(let fingerprint) {
            return fingerprint
        }
        return nil
    }

    static func endpoint(_ text: String) -> SSHEndpoint? {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let hostPort = parts[1].split(separator: ":").map(String.init)
        guard let host = hostPort.first, !host.isEmpty else { return nil }
        let port = hostPort.count > 1 ? Int(hostPort[1]) ?? 22 : 22
        return SSHEndpoint(host: host, port: port, username: parts[0])
    }
}
