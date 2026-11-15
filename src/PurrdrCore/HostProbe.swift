import Foundation

/// 主機作業系統(GLOSSARY「主機」)。Windows 主機在之後的票支援。
public enum HostOperatingSystem: String, Sendable, Hashable, Codable {
    case macOS
    case linux
}

/// herdr 版本。以數值比較(字串比較會讓 `0.10.0` < `0.8.0`,行為規格 §3.1)。
public struct HerdrVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// 最低支援 herdr 0.9.5(ADR-0002)。
    public static let minimumSupported = HerdrVersion(major: 0, minor: 9, patch: 5)

    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 容忍 `herdr ` 前綴、前導 `v` 與 build／預覽尾碼;無法解析回傳 `nil`(視為不支援)。
    public init?(_ text: String) {
        var word = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if word.hasPrefix("herdr ") { word = word.dropFirst("herdr ".count) }
        if word.hasPrefix("v") { word = word.dropFirst() }
        let core = word.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: HerdrVersion, rhs: HerdrVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// herdr 的 agent 整合(`integration.list`)。
public struct AgentIntegration: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        case current
        case outdated
        case notInstalled = "not_installed"
        case unknown
    }

    /// herdr 的整合名稱(`claude`、`codex`、`antigravity_cli`…)。
    public var target: String
    public var label: String
    public var state: State
    /// 主機上找得到這個 agent 的指令。
    public var available: Bool

    public init(target: String, label: String, state: State, available: Bool = true) {
        self.target = target
        self.label = label
        self.state = state
        self.available = available
    }
}

/// 連線測試的結果。
public struct HostProbeReport: Sendable, Equatable {
    public var operatingSystem: HostOperatingSystem
    /// 執行中的 herdr 伺服器版本(UI 顯示這個，行為規格 §3.1)。
    public var herdrVersion: HerdrVersion
    public var agentCount: Int
    /// 主機上有那個 agent 指令的整合。
    public var integrations: [AgentIntegration]

    public init(operatingSystem: HostOperatingSystem, herdrVersion: HerdrVersion, agentCount: Int, integrations: [AgentIntegration]) {
        self.operatingSystem = operatingSystem
        self.herdrVersion = herdrVersion
        self.agentCount = agentCount
        self.integrations = integrations
    }
}

/// 連線測試在 herdr 這一層失敗的原因。連線層的失敗見 `SSHConnectionError`。
public enum HostProbeError: Error, Equatable {
    /// 主機不是 macOS 或 Linux(Windows 之後支援)。
    case unsupportedOperatingSystem(String)
    /// 找不到 herdr(exit 127)。
    case herdrNotInstalled
    /// herdr 路徑跑的不是 herdr(例如 Herdr Desktop 的 `herdr-core`)。
    case notHerdr
    /// herdr 低於 0.9.5。安裝的執行檔或執行中的伺服器其中之一太舊。
    case herdrOutdated(HerdrVersion)
    /// 這個 session 沒有在跑 herdr。
    case serverNotRunning
    /// herdr 回了錯誤(保留原文，行為規格 §3.8)。
    case herdr(String)
    /// `herdr update` 失敗，附主機的錯誤訊息。
    case updateFailed(String)
}

/// 儲存主機前的連線測試：主機 OS → 安裝的 herdr 版本 → 伺服器 ping → snapshot → agent 整合(行為規格 F1.2)。
public struct HostProbe: Sendable {
    private let channel: any HostChannel
    private let herdr: HerdrInstallation

    public init(channel: any HostChannel, herdr: HerdrInstallation) {
        self.channel = channel
        self.herdr = herdr
    }

    public func run() async throws -> HostProbeReport {
        let operatingSystem = try await detectOperatingSystem()

        let version = try await run(HerdrCommand.version(herdr))
        if version.exitCode == 127 { throw HostProbeError.herdrNotInstalled }
        guard version.exitCode == 0, let installed = HerdrVersion(version.stdout) else { throw HostProbeError.notHerdr }
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
            throw HostProbeError.herdr(message)
        }
    }

    /// 更新 herdr(使用者確認後才呼叫)。
    public func updateHerdr() async throws {
        let result = try await run(HerdrCommand.update(herdr))
        guard result.exitCode == 0 else {
            let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostProbeError.updateFailed(message)
        }
    }

    private func detectOperatingSystem() async throws -> HostOperatingSystem {
        let result = try await run(HerdrCommand.operatingSystem)
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (result.exitCode, name) {
        case (0, "Darwin"): return .macOS
        case (0, "Linux"): return .linux
        default: throw HostProbeError.unsupportedOperatingSystem(name.isEmpty ? result.stderr : name)
        }
    }

    /// 執行一般指令，收齊輸出。非零 exit 是結果不是例外(行為規格 §3.2)。
    private func run(_ command: String) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let session = try await channel.execute(command)
        await session.closeStdin()
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = -1
        for try await event in session.output {
            switch event {
            case .stdout(let data): stdout.append(data)
            case .stderr(let data): stderr.append(data)
            case .exit(let code, _): exitCode = code
            }
        }
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), exitCode)
    }
}
