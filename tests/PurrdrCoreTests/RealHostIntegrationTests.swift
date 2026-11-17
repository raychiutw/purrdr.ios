import Foundation
import PurrdrCore
import PurrdrSSH
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
        let server = try await TestSSHServer.start { _ in .runLocally }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)
        let herdr = HerdrInstallation()

        let report = try await HostProbe(channel: channel, herdr: herdr).run()
        #expect(report.herdrVersion >= .minimumSupported)
        let snapshot = try await HerdrClient(channel: channel, herdr: herdr).snapshot()
        print("herdr \(report.herdrVersion) · \(report.operatingSystem) · \(snapshot.agents.count) agents · 整合 \(report.integrations.map(\.target))")
        #expect(snapshot.agents.count == report.agentCount)
        #expect(server.snapshot.connections == 1, "連線沒有重用")
        await channel.disconnect()
        await server.stop()
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
