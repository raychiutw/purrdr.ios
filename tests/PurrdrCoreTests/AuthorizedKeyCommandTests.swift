import PurrdrCore
import Testing

/// 把這支裝置的公鑰加到主機的指令(使用者在主機的終端機貼上執行)。
@Suite("加入公鑰的指令")
struct AuthorizedKeyCommandTests {
    let key = SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr@iPhone")

    @Test("macOS 與 Linux:建立 ~/.ssh、附加到 authorized_keys、權限只給自己")
    func posix() {
        #expect(AuthorizedKeyCommand.command(adding: key, on: .macOSAndLinux)
            == "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr@iPhone' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")
    }

    @Test("Windows(PowerShell):一般使用者加到自己的 authorized_keys")
    func windows() {
        #expect(AuthorizedKeyCommand.command(adding: key, on: .windows)
            == #"New-Item -Force -ItemType Directory -Path "$env:USERPROFILE\.ssh" | Out-Null; Add-Content -Path "$env:USERPROFILE\.ssh\authorized_keys" -Value 'ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr@iPhone'"#)
    }

    @Test("Windows 管理員帳號：OpenSSH 只讀 administrators_authorized_keys,且權限只能給 Administrators 與 SYSTEM")
    func windowsAdministrator() {
        #expect(AuthorizedKeyCommand.command(adding: key, on: .windowsAdministrator)
            == #"Add-Content -Path "$env:ProgramData\ssh\administrators_authorized_keys" -Value 'ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr@iPhone'; icacls.exe "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F""#)
    }

    @Test("註解裡有單引號也不會跳出引號(POSIX 用 '\"'\"',PowerShell 用 '')")
    func quotesComment() {
        let quoted = SSHPublicKey(openSSH: "ssh-ed25519 AAAA Ray's iPhone")
        #expect(AuthorizedKeyCommand.command(adding: quoted, on: .macOSAndLinux).contains(#"echo 'ssh-ed25519 AAAA Ray'"'"'s iPhone' >>"#))
        #expect(AuthorizedKeyCommand.command(adding: quoted, on: .windows).contains("-Value 'ssh-ed25519 AAAA Ray''s iPhone'"))
    }
}
