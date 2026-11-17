import Foundation

/// 主機的作業系統(GLOSSARY「主機」:macOS、Linux 或 Windows)。決定指令方言與路徑語法。
public enum HostOperatingSystem: String, Sendable, Hashable, Codable {
    case macOS
    case linux
    /// 原生 Windows(OpenSSH + herdr Windows 版)。指令一律換成 PowerShell 方言(`WindowsHostChannel`)。
    case windows

    /// 偵測主機作業系統。
    ///
    /// `uname -s` → Darwin／Linux;Git Bash(MSYS2)的 `MINGW64_NT-…`、`MINGW32_NT-…`、`MSYS_NT-…` 是 Windows。
    /// 認不得時(預設 shell 是 cmd 或 PowerShell,沒有 `uname`)再以 PowerShell 探測(行為規格 §3.9)。
    public static func detect(
        on channel: any HostChannel, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> HostOperatingSystem {
        let result = try await channel.collect(HerdrCommand.operatingSystem, deadline: HostCommandDeadline.probe, sleep: sleep)
        let name = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            if name == "Darwin" { return .macOS }
            if name == "Linux" { return .linux }
            if ["MINGW64_NT-", "MINGW32_NT-", "MSYS_NT-"].contains(where: name.hasPrefix) { return .windows }
        }
        let probe = try await channel.collect(PowerShell.windowsProbe, deadline: HostCommandDeadline.probe, sleep: sleep)
        if probe.exitCode == 0, probe.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == PowerShell.windowsMarker {
            return .windows
        }
        throw HostProbeError.unsupportedOperatingSystem(name.isEmpty ? String(decoding: result.stderr, as: UTF8.self) : name)
    }

    /// 這種主機要用的通道:Windows 換成 PowerShell 方言，其他原樣。
    public func channel(_ base: any HostChannel) -> any HostChannel {
        self == .windows ? WindowsHostChannel(base) : base
    }
}
