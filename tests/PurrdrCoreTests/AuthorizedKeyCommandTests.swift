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

    /// 繁中 Windows 主控台是 CP950,Windows PowerShell 5.1 會把貼上的非 ASCII 讀壞、破壞引號(#342 實測):
    /// 給使用者複製到 Windows 的指令一律只含 ASCII,公鑰註解裡的非 ASCII 字元拿掉(整段都不是 ASCII 就退回 purrdr)。
    @Test("Windows 指令只含 ASCII:公鑰註解有中文也一樣")
    func windowsCommandsAreASCII() {
        let chinese = SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 AAAAE2VjZHNh Ray 的 iPhone")
        let onlyChinese = SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 AAAAE2VjZHNh 我的手機")
        for platform in [AuthorizedKeyCommand.Platform.windows, .windowsAdministrator] {
            for key in [chinese, onlyChinese] {
                let command = AuthorizedKeyCommand.command(adding: key, on: platform)
                #expect(command.unicodeScalars.allSatisfy { $0.isASCII }, "\(platform): \(command)")
                #expect(command.contains("ecdsa-sha2-nistp256 AAAAE2VjZHNh"))
            }
        }
        #expect(AuthorizedKeyCommand.command(adding: chinese, on: .windows).contains("-Value 'ecdsa-sha2-nistp256 AAAAE2VjZHNh Ray  iPhone'"))
        #expect(AuthorizedKeyCommand.command(adding: onlyChinese, on: .windows).contains("-Value 'ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr'"))
    }

    @Test("macOS 與 Linux 的指令保留原本的註解(終端機是 UTF-8)")
    func posixKeepsComment() {
        let chinese = SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 AAAAE2VjZHNh 我的手機")
        #expect(AuthorizedKeyCommand.command(adding: chinese, on: .macOSAndLinux).contains("echo 'ecdsa-sha2-nistp256 AAAAE2VjZHNh 我的手機' >>"))
    }
}
