/// 把公鑰加進主機 `authorized_keys` 的指令，給使用者在主機的終端機貼上執行。
///
/// Windows 的路徑與權限依 Microsoft 的 OpenSSH 金鑰管理文件:管理員帳號的金鑰要放
/// `%ProgramData%\ssh\administrators_authorized_keys`,而且只能讓 Administrators 與 SYSTEM 存取。
public enum AuthorizedKeyCommand {
    public enum Platform: CaseIterable, Sendable {
        case macOSAndLinux
        case windows
        case windowsAdministrator
    }

    public static func command(adding key: SSHPublicKey, on platform: Platform) -> String {
        switch platform {
        case .macOSAndLinux:
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \(PosixShell.quote(key.openSSH)) >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        case .windows:
            #"New-Item -Force -ItemType Directory -Path "$env:USERPROFILE\.ssh" | Out-Null; "#
                + #"Add-Content -Path "$env:USERPROFILE\.ssh\authorized_keys" -Value "# + powerShellQuote(key.openSSH)
        case .windowsAdministrator:
            #"Add-Content -Path "$env:ProgramData\ssh\administrators_authorized_keys" -Value "# + powerShellQuote(key.openSSH)
                + #"; icacls.exe "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F""#
        }
    }

    /// PowerShell 單引號字串：內部單引號寫兩次。
    private static func powerShellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
