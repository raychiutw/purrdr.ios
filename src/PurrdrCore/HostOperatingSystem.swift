import Foundation

/// 主機的作業系統(GLOSSARY「主機」:macOS、Linux 或 Windows)。決定指令方言與路徑語法。
public enum HostOperatingSystem: String, Sendable, Hashable, Codable {
    case macOS
    case linux
    /// 原生 Windows(OpenSSH + herdr Windows 版)。指令一律換成 PowerShell 方言(`WindowsHostChannel`)。
    case windows
}
