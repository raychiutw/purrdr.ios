import Foundation
import PurrdrCore

/// 儲存主機前的連線測試：主機 OS → 安裝的 herdr 版本 → 伺服器 ping → snapshot → agent 整合(行為規格 F1.2)。
public struct HostProbe: Sendable {
    private let channel: any HostChannel
    private let herdr: HerdrInstallation
    /// 指令期限的計時(測試注入)。
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        channel: any HostChannel, herdr: HerdrInstallation,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.channel = channel
        self.herdr = herdr
        self.sleep = sleep
    }

    public func run() async throws -> HostProbeReport {
        let operatingSystem = try await detectOperatingSystem()
        // 偵測到 Windows 之後，指令一律換成 PowerShell 方言。
        let channel = operatingSystem.channel(channel)

        let version = try await channel.collect(HerdrCommand.version(herdr), deadline: HostCommandDeadline.standard, sleep: sleep)
        if version.exitCode == 127 { throw HostProbeError.herdrNotInstalled }
        guard version.exitCode == 0, let installed = HerdrVersion(version.stdoutText) else { throw HostProbeError.notHerdr }
        guard installed >= .minimumSupported else { throw HostProbeError.herdrOutdated(installed) }

        let client = HerdrClient(channel: channel, herdr: herdr)
        do {
            let serverText = try await client.ping()
            guard let server = HerdrVersion(serverText), server >= .minimumSupported else {
                throw HostProbeError.herdrOutdated(HerdrVersion(serverText) ?? installed)
            }
            let snapshot = try await client.snapshot()
            let integrations = try await client.integrations().filter(\.available)
            return HostProbeReport(
                operatingSystem: operatingSystem, herdrVersion: server, agentCount: snapshot.agents.count, integrations: integrations)
        } catch HerdrError.herdr(code: "server_not_running", _) {
            throw HostProbeError.serverNotRunning
        } catch HerdrError.herdr(_, let message) {
            throw HostProbeError.herdr(WindowsErrorText.readable(message))
        }
    }

    /// 更新 herdr(使用者確認後才呼叫)。
    ///
    /// macOS／Linux 以 `update --handoff` 讓執行中的伺服器交接到新版;Windows 不支援 live handoff
    /// (`ping` 的 `capabilities.live_handoff` 是 `false`),只換執行檔，要使用者在主機上重啟伺服器(行為規格 §11.1)。
    @discardableResult
    public func updateHerdr() async throws -> HerdrUpdateOutcome {
        let operatingSystem = try await detectOperatingSystem()
        let result = try await operatingSystem.channel(channel)
            .collect(HerdrCommand.update(herdr), deadline: HostCommandDeadline.download, sleep: sleep)
        guard result.exitCode == 0 else {
            let message = (result.stderr.isEmpty ? result.stdoutText : String(decoding: result.stderr, as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostProbeError.updateFailed(WindowsErrorText.readable(message))
        }
        return operatingSystem == .windows ? .restartServerRequired : .handedOff
    }

    private func detectOperatingSystem() async throws -> HostOperatingSystem {
        try await HostOperatingSystem.detect(on: channel, sleep: sleep)
    }
}
