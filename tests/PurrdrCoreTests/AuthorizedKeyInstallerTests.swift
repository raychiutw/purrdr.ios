import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 用密碼登入後把這支裝置的公鑰寫進主機(#285,ADR-0002 的可還原寫入)。
@Suite("用密碼加入公鑰")
struct AuthorizedKeyInstallerTests {
    static let key = SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr@iPhone")
    static let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNh purrdr@iPhone"
    static let authorizedKeys = ".ssh/authorized_keys"

    static func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

    @Test("macOS／Linux 沒有 ~/.ssh:建立資料夾並寫入帶 Purrdr 裝置註解的公鑰行")
    func addsKeyWhenNoSSHDirectory() async throws {
        let host = FakeHost()
        await host.serveHomeFiles()

        let outcome = try await AuthorizedKeyInstaller(channel: host).install(Self.key)

        #expect(outcome == .added)
        #expect(Self.text(await host.homeFiles[Self.authorizedKeys]) == Self.line + "\n")
    }

    @Test("既有的 authorized_keys(結尾沒有換行):保留原本的行，換行後加在最後")
    func appendsAfterExistingKeys() async throws {
        let host = FakeHost()
        await host.serveHomeFiles([Self.authorizedKeys: Data("ssh-ed25519 AAAAother laptop".utf8)])

        let outcome = try await AuthorizedKeyInstaller(channel: host).install(Self.key)

        #expect(outcome == .added)
        #expect(Self.text(await host.homeFiles[Self.authorizedKeys]) == "ssh-ed25519 AAAAother laptop\n" + Self.line + "\n")
    }

    @Test("同一把公鑰已在檔案裡(註解不同也算):不重複加入、不寫任何東西")
    func skipsKeyAlreadyPresent() async throws {
        let existing = "ssh-ed25519 AAAAother laptop\necdsa-sha2-nistp256 AAAAE2VjZHNh added by hand\n"
        let host = FakeHost()
        await host.serveHomeFiles([Self.authorizedKeys: Data(existing.utf8)])

        let outcome = try await AuthorizedKeyInstaller(channel: host).install(Self.key)

        #expect(outcome == .alreadyPresent)
        #expect(await host.homeFiles == [Self.authorizedKeys: Data(existing.utf8)])
    }

    @Test("還原：拿掉加入的那一行，安裝後使用者另外加的行保留")
    func restoreRemovesOnlyOurLine() async throws {
        let host = FakeHost()
        await host.serveHomeFiles([Self.authorizedKeys: Data("ssh-ed25519 AAAAother laptop\n".utf8)])
        let installer = AuthorizedKeyInstaller(channel: host)
        try await installer.install(Self.key)
        var edited = try #require(await host.homeFiles[Self.authorizedKeys])
        #expect(Self.text(edited) == "ssh-ed25519 AAAAother laptop\n" + Self.line + "\n")
        edited.append(Data("ssh-ed25519 AAAAnew tablet\n".utf8))
        await host.serveHomeFiles(await host.homeFiles.merging([Self.authorizedKeys: edited]) { $1 }, directories: [".ssh"])

        try await installer.restore(Self.key)

        #expect(await host.homeFiles == [Self.authorizedKeys: Data("ssh-ed25519 AAAAother laptop\nssh-ed25519 AAAAnew tablet\n".utf8)])
    }

    static let administratorRecord = ".purrdr/authorized-key/administrators_authorized_keys.json"

    @Test("Windows 一般使用者：寫到自己家目錄的 .ssh\\authorized_keys")
    func windowsStandardUserWritesHomeFile() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.expect(AuthorizedKeyInstaller.AdministratorRequest.read.command, reply: FakeReply(stdout: Data("user\n".utf8)))

        let outcome = try await AuthorizedKeyInstaller(channel: host).install(Self.key)

        #expect(outcome == .added)
        #expect(Self.text(await host.homeFiles[Self.authorizedKeys]) == Self.line + "\n")
    }

    @Test("Windows 管理員帳號：寫到 administrators_authorized_keys,安裝前的內容備份在 ~/.purrdr,家目錄的 authorized_keys 不動")
    func windowsAdministratorBacksUpBeforeWriting() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.serveAdministratorKeys(Data("ssh-ed25519 AAAAother laptop\r\n".utf8))

        let outcome = try await AuthorizedKeyInstaller(channel: host).install(Self.key)

        #expect(outcome == .added)
        #expect(Self.text(await host.administratorKeys) == "ssh-ed25519 AAAAother laptop\r\n" + Self.line + "\r\n")
        #expect(await host.homeFiles[Self.authorizedKeys] == nil)
        #expect(await host.homeFiles[Self.administratorRecord] != nil)
    }

    @Test("Windows 管理員帳號還原：檔案沒再改過就換回安裝前的內容，並移除 ~/.purrdr 的備份")
    func windowsAdministratorRestoreReturnsOriginal() async throws {
        let original = Data("ssh-ed25519 AAAAother laptop".utf8)
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.serveAdministratorKeys(original)
        let installer = AuthorizedKeyInstaller(channel: host)
        try await installer.install(Self.key)

        try await installer.restore(Self.key)

        #expect(await host.administratorKeys == original)
        #expect(await host.homeFiles.keys.filter { $0.hasPrefix(".purrdr/") }.isEmpty)
    }

    @Test("Windows 管理員帳號還原：原本沒有檔案就刪掉")
    func windowsAdministratorRestoreDeletesCreatedFile() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.serveAdministratorKeys(nil)
        let installer = AuthorizedKeyInstaller(channel: host)
        try await installer.install(Self.key)
        #expect(Self.text(await host.administratorKeys) == Self.line + "\r\n")

        try await installer.restore(Self.key)

        #expect(await host.administratorKeys == nil)
    }

    @Test("Windows 管理員帳號還原：安裝後使用者又加了別的公鑰，只拿掉加入的那一行")
    func windowsAdministratorRestoreKeepsLaterLines() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.serveAdministratorKeys(Data("ssh-ed25519 AAAAother laptop\r\n".utf8))
        let installer = AuthorizedKeyInstaller(channel: host)
        try await installer.install(Self.key)
        let installed = try #require(await host.administratorKeys)
        await host.serveAdministratorKeys(installed + Data("ssh-ed25519 AAAAnew tablet\r\n".utf8))

        try await installer.restore(Self.key)

        #expect(Self.text(await host.administratorKeys) == "ssh-ed25519 AAAAother laptop\r\nssh-ed25519 AAAAnew tablet\r\n")
    }

    @Test("Windows 管理員帳號已有這把公鑰：不重複加入，也不留備份")
    func windowsAdministratorKeyAlreadyPresent() async throws {
        let existing = Data("ecdsa-sha2-nistp256 AAAAE2VjZHNh added by hand\r\n".utf8)
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.serveAdministratorKeys(existing)

        #expect(try await AuthorizedKeyInstaller(channel: host).install(Self.key) == .alreadyPresent)
        #expect(await host.administratorKeys == existing)
        #expect(await host.homeFiles.isEmpty)
    }

    @Test("Windows 管理員帳號：讀取之後檔案被改過就整個不寫，丟出 changedSinceRead")
    func windowsAdministratorChangedSinceReadWritesNothing() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.expect(AuthorizedKeyInstaller.AdministratorRequest.read.command, reply: FakeReply(stdout: Data("missing\n".utf8)))
        await host.expect(
            AuthorizedKeyInstaller.AdministratorRequest.write(expected: nil, contents: Data((Self.line + "\r\n").utf8)).command,
            reply: FakeReply(stdout: Data("changed\n".utf8)))

        await #expect(throws: AuthorizedKeyInstallError.changedSinceRead) {
            try await AuthorizedKeyInstaller(channel: host).install(Self.key)
        }
    }

    @Test("Windows 主機通道把管理員指令換成 PowerShell:管理員才讀寫 administrators_authorized_keys,寫入後權限只給 Administrators 與 SYSTEM")
    func windowsChannelRunsAdministratorScript() async throws {
        let contents = Data("ssh-ed25519 AAAA Ray's iPhone\r\n".utf8)
        let host = FakeHost()

        let sent: String
        do {
            _ = try await WindowsHostChannel(host).execute(
                AuthorizedKeyInstaller.AdministratorRequest.write(expected: nil, contents: contents).command)
            Issue.record("假主機應該收到沒預期的 PowerShell 指令")
            return
        } catch FakeHostError.unexpectedCommand(let command) {
            sent = command
        }

        let script = try #require(PowerShell.script(inEncodedCommand: sent))
        #expect(script.contains("WindowsBuiltInRole]::Administrator"))
        #expect(script.contains(#"ssh\administrators_authorized_keys"#))
        #expect(script.contains("/inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'"))
        #expect(script.contains(contents.base64EncodedString()))
    }

    @Test("主機上寫入失敗：丟出主機的原因，不當成成功")
    func failureCarriesHostReason() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(windowsHome: "C:/Users/demo")
        await host.expect(AuthorizedKeyInstaller.AdministratorRequest.read.command, reply: FakeReply(stdout: Data("missing\n".utf8)))
        await host.expect(
            AuthorizedKeyInstaller.AdministratorRequest.write(expected: nil, contents: Data((Self.line + "\r\n").utf8)).command,
            reply: FakeReply(stderr: Data("icacls: Access is denied.\n".utf8), exitCode: 1))

        await #expect(throws: AuthorizedKeyInstallError.failed("icacls: Access is denied.")) {
            try await AuthorizedKeyInstaller(channel: host).install(Self.key)
        }
    }
}
