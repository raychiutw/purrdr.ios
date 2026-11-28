import Crypto
import Foundation
import NIOSSH
import PurrdrCore
import PurrdrTestSupport
import Testing

/// OpenSSH 主機的登入：公鑰(匯入的金鑰、這支裝置的金鑰)與密碼。對本機的測試用 SSH 伺服器跑。
@Suite("OpenSSH 認證")
struct SSHAuthenticationTests {
    @Test("公鑰登入：主機認得這把公鑰就放行，指令照常執行")
    func signsInWithPublicKey() async throws {
        let key = SSHPrivateKey(p256: P256.Signing.PrivateKey())
        let server = try await TestSSHServer.start(authentication: .publicKeys([try key.nioPublicKey()])) { _ in .reply(stdout: "ok") }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .privateKey(key) }

        let result = try await collect(channel.execute("whoami"))

        #expect(result.stdout == "ok")
        // 先以 none 問主機接受哪些方式(與 OpenSSH client 相同)，再用公鑰。
        #expect(server.snapshot.authenticationAttempts == ["none", "publickey"])
        await channel.disconnect()
    }

    #if os(macOS)
    @Test("匯入的金鑰(ssh-keygen 產生)可以登入", arguments: ["ed25519", "ecdsa"])
    func signsInWithImportedKey(type: String) async throws {
        let generated = try SSHKeygen.generate(type: type)
        defer { generated.remove() }
        let key = try SSHPrivateKey(openSSH: generated.privateText)
        let authorized = try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyWithoutComment)
        let server = try await TestSSHServer.start(authentication: .publicKeys([authorized])) { _ in .reply(stdout: "ok") }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .privateKey(key) }

        #expect(try await collect(channel.execute("x")).stdout == "ok")
        await channel.disconnect()
    }
    #endif

    @Test("主機不認得這把公鑰：登入失敗，不執行指令")
    func unknownPublicKeyIsRejected() async throws {
        let authorized = SSHPrivateKey(p256: P256.Signing.PrivateKey())
        let other = SSHPrivateKey(p256: P256.Signing.PrivateKey())
        let server = try await TestSSHServer.start(authentication: .publicKeys([try authorized.nioPublicKey()])) { _ in .reply() }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .privateKey(other) }

        await #expect(throws: SSHConnectionError.authenticationFailed) { _ = try await channel.execute("x") }
        #expect(server.snapshot.commands.isEmpty)
    }

    @Test("密碼登入：密碼對就放行;密碼錯只試一次就回報登入失敗")
    func signsInWithPassword() async throws {
        let server = try await TestSSHServer.start(authentication: .password("hunter2")) { _ in .reply(stdout: "ok") }
        defer { server.stop() }

        let right = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .password("hunter2") }
        #expect(try await collect(right.execute("x")).stdout == "ok")
        await right.disconnect()

        let wrong = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .password("hunter3") }
        await #expect(throws: SSHConnectionError.authenticationFailed) { _ = try await wrong.execute("x") }
        #expect(server.snapshot.authenticationAttempts == ["none", "password", "none", "password"])
        #expect(server.snapshot.commands == ["x"])
    }

    @Test("主機不接受這種登入方式(例如只開 keyboard-interactive):說明方式不被接受，不送出祕密")
    func methodNotAccepted() async throws {
        let server = try await TestSSHServer.start(authentication: .keyboardInteractiveOnly) { _ in .reply() }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .password("hunter2") }

        await #expect(throws: SSHConnectionError.authenticationMethodNotAccepted) { _ = try await channel.execute("x") }
        #expect(!server.snapshot.authenticationAttempts.contains("password"), "主機沒有開密碼登入，卻送出了密碼")
    }

    @Test("讀不到憑證(例如還原備份後祕密不在):連線前就失敗，不撥號")
    func credentialFailureStopsBeforeDialing() async throws {
        struct Missing: Error, Equatable {}
        let server = try await TestSSHServer.start(authentication: .password("x")) { _ in .reply() }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { throw Missing() }

        await #expect(throws: Missing()) { _ = try await channel.execute("x") }
        #expect(server.snapshot.connections == 0)
    }

    @Test("沒有 pin 時不送出任何憑證(先確認 host key)")
    func noCredentialBeforeHostKeyIsTrusted() async throws {
        let server = try await TestSSHServer.start(authentication: .password("hunter2")) { _ in .reply() }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: nil) { .password("hunter2") }

        await #expect(throws: SSHConnectionError.hostKeyUnverified(presented: server.fingerprint)) { _ = try await channel.execute("x") }
        #expect(server.snapshot.authenticationAttempts.isEmpty)
    }
}

extension SSHPrivateKey {
    func nioPublicKey() throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: publicKey.openSSH)
    }
}
