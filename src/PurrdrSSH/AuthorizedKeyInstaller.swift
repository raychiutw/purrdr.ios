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
    /// 讀取之後 `administrators_authorized_keys` 被改過：沒有寫入。
    case changedSinceRead
}

/// 把這支裝置的公鑰寫進主機的 `authorized_keys`(#285,ADR-0002 的寫入例外)。呼叫端以密碼登入的通道執行。
///
/// - macOS／Linux 與 Windows 一般使用者：`~/.ssh/authorized_keys`,經 `ReversibleHostWrite`(還原時只拿掉這一行)。
///   POSIX 的主機檔案腳本以 `umask 077` 建立資料夾與檔案(700／600),同 `AuthorizedKeyCommand`。
/// - Windows 管理員帳號：OpenSSH 只讀 `%ProgramData%\ssh\administrators_authorized_keys`,不在家目錄底下。
///   寫入前把安裝前的內容備份到 `~/.purrdr/authorized-key/`(同 `ReversibleHostWrite` 的安裝紀錄),還原時沒再改過就換回原狀，
///   改過就只拿掉這一行;讀寫由 Windows 主機通道換成的 PowerShell 以 compare-and-swap 執行，權限收成 Administrators 與 SYSTEM。
/// - 同一把公鑰(演算法與 base64 相同，註解不論)已在檔案裡就不寫。
public struct AuthorizedKeyInstaller: Sendable {
    public static let authorizedKeysPath: HostPath = ".ssh/authorized_keys"
    public static let feature = HostWriteFeature(id: "authorized-key", userFiles: [authorizedKeysPath], createsParentDirectories: true)
    /// Windows 管理員檔案安裝前內容的備份(`feature` 的自有檔案)。
    static let administratorRecordName = "administrators_authorized_keys.json"
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
        let recordPath = Self.feature.ownFile(Self.administratorRecordName)
        let inspection = try await write.inspect(also: [recordPath])
        if inspection.read.isWindows, case .administrator(let current) = try await readAdministrator() {
            if Self.contains(key, in: current) { return .alreadyPresent }
            let installed = Self.appending(key, to: current ?? Data(), lineEnding: "\r\n")
            // 重複安裝沿用第一次的備份。
            let original = Self.administratorRecord(in: inspection).map(\.original) ?? current
            let record = try JSONEncoder().encode(AdministratorRecord(original: original, installed: installed))
            try await write.install(also: [recordPath]) { _ in
                HostWritePlan(userFiles: [:], ownFiles: [Self.administratorRecordName: .init(record)])
            }
            try await writeAdministrator(expected: current, contents: installed)
            return .added
        }
        if Self.contains(key, in: inspection.read[Self.authorizedKeysPath]?.contents) { return .alreadyPresent }
        try await write.install { inspection in
            let current = inspection.read[Self.authorizedKeysPath]?.contents ?? Data()
            return HostWritePlan(userFiles: [Self.authorizedKeysPath: Self.appending(key, to: current)], ownFiles: [:])
        }
        return .added
    }

    /// 還原：使用者檔案拿掉加入的那一行(使用者後來加的行保留);Windows 管理員檔案沒再改過就換回安裝前的內容。
    public func restore(_ key: SSHPublicKey) async throws {
        let inspection = try await write.inspect(also: [Self.feature.ownFile(Self.administratorRecordName)])
        if inspection.read.isWindows, let record = Self.administratorRecord(in: inspection),
           case .administrator(let current?) = try await readAdministrator() {
            let target = current == record.installed ? record.original : Self.removing(key, from: current)
            if target != current { try await writeAdministrator(expected: current, contents: target) }
        }
        try await write.restore { _, current, _ in Self.removing(key, from: current) }
    }

    // MARK: - Windows 管理員檔案

    /// 讀寫 Windows 管理員檔案的指令;在 Windows 主機上回 `user`／`missing`／`file <base64>`(讀)或 `written`／`changed`(寫)。
    public enum AdministratorRequest: Sendable, Equatable {
        case read
        /// 目前內容是 `expected`(`nil` 是不存在)才寫成 `contents`(`nil` 是刪除)。
        case write(expected: Data?, contents: Data?)

        public var command: String {
            switch self {
            case .read:
                ([administratorProgram] + ["read"].map(PosixShell.quote)).joined(separator: " ")
            case .write(let expected, let contents):
                ([administratorProgram] + ["write", Self.token(expected), Self.token(contents)].map(PosixShell.quote)).joined(separator: " ")
            }
        }

        public init?(command: String) {
            guard command.hasPrefix(administratorProgram + " "),
                  let arguments = PosixShell.unquote(String(command.dropFirst(administratorProgram.count + 1))) else { return nil }
            switch arguments.first {
            case "read" where arguments.count == 1:
                self = .read
            case "write" where arguments.count == 3:
                guard let expected = Self.data(arguments[1]), let contents = Self.data(arguments[2]) else { return nil }
                self = .write(expected: expected, contents: contents)
            default:
                return nil
            }
        }

        /// `-` 是不存在;其他是 base64。
        private static func token(_ data: Data?) -> String { data.map { "b" + $0.base64EncodedString() } ?? "-" }

        private static func data(_ token: String) -> Data?? {
            if token == "-" { return .some(nil) }
            guard token.hasPrefix("b"), let data = Data(base64Encoded: String(token.dropFirst())) else { return nil }
            return .some(data)
        }
    }

    /// `AdministratorRequest` 的 PowerShell 版本;不是這個指令時是 `nil`。
    static func administratorScript(for command: String) -> String? {
        switch AdministratorRequest(command: command) {
        case nil:
            return nil
        case .read:
            return administratorPrelude + administratorRead
        case .write(let expected, let contents):
            return administratorPrelude
                + "$expected=\(powerShellBytes(expected))\n$contents=\(powerShellBytes(contents))\n"
                + administratorWrite
        }
    }

    enum AdministratorState: Equatable {
        /// 不是管理員：改寫家目錄的檔案。
        case standardUser
        /// 管理員;`nil` 是檔案不存在。
        case administrator(Data?)
    }

    private func readAdministrator() async throws -> AdministratorState {
        let output = try await runAdministrator(.read)
        if output == "user" { return .standardUser }
        if output == "missing" { return .administrator(nil) }
        guard output.hasPrefix("file "), let data = Data(base64Encoded: String(output.dropFirst("file ".count))) else {
            throw AuthorizedKeyInstallError.failed(output)
        }
        return .administrator(data)
    }

    private func writeAdministrator(expected: Data?, contents: Data?) async throws {
        switch try await runAdministrator(.write(expected: expected, contents: contents)) {
        case "written": return
        case "changed": throw AuthorizedKeyInstallError.changedSinceRead
        case let output: throw AuthorizedKeyInstallError.failed(output)
        }
    }

    private func runAdministrator(_ request: AdministratorRequest) async throws -> String {
        let result = try await channel.collect(request.command, deadline: HostCommandDeadline.standard, sleep: Sleeping.task)
        guard result.exitStatus == 0 else {
            let reason = result.stderrText
            throw AuthorizedKeyInstallError.failed(reason.isEmpty ? "exit \(result.exitCode)" : reason)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Windows 管理員檔案安裝前與安裝後的內容。
    struct AdministratorRecord: Codable {
        var original: Data?
        var installed: Data
    }

    private static func administratorRecord(in inspection: HostWriteInspection) -> AdministratorRecord? {
        guard case .file(let data, _)? = inspection.read[feature.ownFile(administratorRecordName)] else { return nil }
        return try? JSONDecoder().decode(AdministratorRecord.self, from: data)
    }

    // MARK: - 內容

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

    static func appending(_ key: SSHPublicKey, to current: Data, lineEnding: String = "\n") -> Data {
        var updated = current
        if let last = current.last, last != 0x0A { updated.append(Data(lineEnding.utf8)) }
        updated.append(Data((key.openSSH + lineEnding).utf8))
        return updated
    }

    static func removing(_ key: SSHPublicKey, from current: Data) -> Data {
        // 以位元組切行：Swift 字串把 CRLF 當成一個字元，Windows 的檔案會切不開。
        let lines = current.split(separator: 0x0A, omittingEmptySubsequences: false)
        let kept = lines.filter { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != key.openSSH }
        return Data(kept.joined(separator: [0x0A]))
    }

    private static func powerShellBytes(_ data: Data?) -> String {
        data.map { "[Convert]::FromBase64String('\($0.base64EncodedString())')" } ?? "$null"
    }

    /// 不是管理員回 `user`(呼叫端改寫家目錄的檔案)。
    private static let administratorPrelude = #"""
        $ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop'
        $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){'user';exit 0}
        $path=Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

        """#

    private static let administratorRead = #"""
        if(-not (Test-Path -LiteralPath $path)){'missing';exit 0}
        'file '+[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
        """#

    /// 目前內容與 `$expected` 相同才寫(`$contents` 是 `$null` 就刪除),寫完收權限。
    private static let administratorWrite = #"""
        $exists=Test-Path -LiteralPath $path
        if($exists -ne ($null -ne $expected)){'changed';exit 0}
        if($exists -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ne [Convert]::ToBase64String($expected))){'changed';exit 0}
        if($null -eq $contents){Remove-Item -LiteralPath $path -Force;'written';exit 0}
        [IO.File]::WriteAllBytes($path,$contents)
        & icacls.exe $path /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        if($LASTEXITCODE -ne 0){[Console]::Error.WriteLine("icacls exit $LASTEXITCODE");exit 1}
        'written'
        """#
}
