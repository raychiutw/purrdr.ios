import Foundation
import PurrdrCore

/// 用密碼加入公鑰的結果。
public enum AuthorizedKeyInstallOutcome: Sendable, Equatable {
    case added
    /// 同一把公鑰已在檔案裡，沒有寫入。
    case alreadyPresent
}

public enum AuthorizedKeyInstallError: Error, Equatable {
    /// 主機上的寫入失敗，帶主機的錯誤輸出。
    case failed(String)
}

/// 把這支裝置的公鑰寫進主機的 `authorized_keys`(#285,ADR-0002 的寫入例外)。呼叫端以密碼登入的通道執行。
///
/// - macOS／Linux 與 Windows 一般使用者：`~/.ssh/authorized_keys`,經 `ReversibleHostWrite`(還原時只拿掉這一行)。
///   POSIX 的主機檔案腳本以 `umask 077` 建立資料夾與檔案(700／600),同 `AuthorizedKeyCommand`。
/// - Windows 管理員帳號：OpenSSH 只讀 `%ProgramData%\ssh\administrators_authorized_keys`,不在家目錄底下，
///   由 Windows 主機通道換成的 PowerShell 腳本寫入並把權限收成 Administrators 與 SYSTEM(以 SID 指定，不受語系影響)。
/// - 同一把公鑰(演算法與 base64 相同，註解不論)已在檔案裡就不寫。
public struct AuthorizedKeyInstaller: Sendable {
    public enum AdministratorAction: String, Sendable {
        case install
        case remove
    }

    public static let authorizedKeysPath: HostPath = ".ssh/authorized_keys"
    public static let feature = HostWriteFeature(id: "authorized-key", userFiles: [authorizedKeysPath], createsParentDirectories: true)
    /// Windows 管理員檔案的指令名稱：只會送到 Windows 主機，由 `WindowsHostChannel` 換成 PowerShell。
    static let administratorProgram = "purrdr-administrators-authorized-keys"

    let channel: any HostChannel
    let write: ReversibleHostWrite

    public init(channel: any HostChannel) {
        self.channel = channel
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
    }

    @discardableResult
    public func install(_ key: SSHPublicKey) async throws -> AuthorizedKeyInstallOutcome {
        let inspection = try await write.inspect()
        if inspection.read.isWindows {
            switch try await runAdministrator(.install, key: key) {
            case "added": return .added
            case "present": return .alreadyPresent
            default: break
            }
        }
        if Self.contains(key, in: inspection.read[Self.authorizedKeysPath]?.contents) { return .alreadyPresent }
        try await write.install { inspection in
            let current = inspection.read[Self.authorizedKeysPath]?.contents ?? Data()
            return HostWritePlan(userFiles: [Self.authorizedKeysPath: Self.appending(key, to: current)], ownFiles: [:])
        }
        return .added
    }

    /// 拿掉加入的那一行;使用者後來加的行保留。
    public func restore(_ key: SSHPublicKey) async throws {
        let inspection = try await write.inspect()
        if inspection.read.isWindows, try await runAdministrator(.remove, key: key) == "removed" { return }
        try await write.restore { _, current, _ in Self.removing(key, from: current) }
    }

    /// Windows 管理員檔案的指令(在 Windows 主機上回 `user`／`added`／`present`／`removed`)。
    public static func administratorCommand(_ action: AdministratorAction, key: SSHPublicKey) -> String {
        "\(administratorProgram) \(PosixShell.quote(action.rawValue)) \(PosixShell.quote(key.openSSH))"
    }

    /// `administratorCommand` 的 PowerShell 版本;不是這個指令時是 `nil`。
    static func administratorScript(for command: String) -> String? {
        guard command.hasPrefix(administratorProgram + " "),
              let arguments = PosixShell.unquote(String(command.dropFirst(administratorProgram.count))), arguments.count == 2,
              let action = AdministratorAction(rawValue: arguments[0]) else { return nil }
        let line = "'" + arguments[1].replacingOccurrences(of: "'", with: "''") + "'"
        return administratorPrelude.replacingOccurrences(of: "<LINE>", with: line) + (action == .install ? administratorInstall : administratorRemove)
    }

    private func runAdministrator(_ action: AdministratorAction, key: SSHPublicKey) async throws -> String {
        let result = try await channel.collect(
            Self.administratorCommand(action, key: key), deadline: HostCommandDeadline.standard, sleep: Sleeping.task)
        guard result.exitStatus == 0 else {
            let reason = result.stderrText
            throw AuthorizedKeyInstallError.failed(reason.isEmpty ? "exit \(result.exitCode)" : reason)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contains(_ key: SSHPublicKey, in data: Data?) -> Bool {
        guard let data else { return false }
        let wanted = key.openSSH.split(separator: " ").prefix(2).map(String.init)
        guard wanted.count == 2 else { return false }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            // 前面可能有選項(例如 `from="…"`):找相鄰的演算法與 base64。
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.indices.dropLast().contains(where: { fields[$0] == wanted[0] && fields[$0 + 1] == wanted[1] }) { return true }
        }
        return false
    }

    static func appending(_ key: SSHPublicKey, to current: Data) -> Data {
        var updated = current
        if let last = current.last, last != 0x0A { updated.append(0x0A) }
        updated.append(Data((key.openSSH + "\n").utf8))
        return updated
    }

    static func removing(_ key: SSHPublicKey, from current: Data) -> Data {
        let lines = String(decoding: current, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != key.openSSH }
        return Data(kept.joined(separator: "\n").utf8)
    }

    /// 不是管理員回 `user`(呼叫端改寫家目錄的檔案)。
    private static let administratorPrelude = #"""
        $ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop'
        $line=<LINE>
        $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){'user';exit 0}
        $path=Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        $text=''
        if(Test-Path -LiteralPath $path){$text=[IO.File]::ReadAllText($path)}
        $lines=@($text -split "`r?`n")

        """#

    private static let administratorInstall = #"""
        $want=($line -split ' ')[0..1] -join ' '
        foreach($l in $lines){$f=@($l.Trim() -split '\s+');for($i=0;$i -lt $f.Count-1;$i++){if(($f[$i]+' '+$f[$i+1]) -eq $want){'present';exit 0}}}
        if($text.Length -gt 0 -and -not $text.EndsWith("`n")){$text+="`r`n"}
        [IO.File]::WriteAllText($path,$text+$line+"`r`n")
        & icacls.exe $path /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        if($LASTEXITCODE -ne 0){[Console]::Error.WriteLine("icacls exit $LASTEXITCODE");exit 1}
        'added'
        """#

    private static let administratorRemove = #"""
        $kept=@($lines | Where-Object {$_.Trim() -ne $line})
        if($kept.Count -ne $lines.Count){[IO.File]::WriteAllText($path,($kept -join "`r`n"))}
        'removed'
        """#
}
