import Crypto
import Foundation
import NIOSSH
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 測試用 SSH 伺服器的 `.runLocally` 會以開發者身分跑 `/bin/sh`,所以一定要搭配公鑰認證(#695)。
@Suite("測試用 SSH 伺服器的本機執行")
struct TestSSHServerLocalRunTests {
    @Test("none 認證搭配 runLocally:拒絕執行,指令沒有在本機跑")
    func noneAuthenticationRefusesLocalRun() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "purrdr-695-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let server = try await TestSSHServer.start { _ in .runLocally }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        let result = try? await collect(channel.execute("touch '\(marker.path)'; printf ran"))

        #expect(result?.stdout != "ran")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(server.snapshot.refusedLocalRuns == 1)
        await channel.disconnect()
    }

    @Test("公鑰認證搭配 runLocally:用對的公鑰連得上並在本機執行")
    func publicKeyAllowsLocalRun() async throws {
        let key = SSHPrivateKey(p256: P256.Signing.PrivateKey())
        let server = try await TestSSHServer.start(authentication: .publicKeys([try key.nioPublicKey()])) { _ in .runLocally }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .privateKey(key) }

        #expect(try await collect(channel.execute("printf ran")).stdout == "ran")
        #expect(server.snapshot.refusedLocalRuns == 0)
        await channel.disconnect()
    }

    @Test("公鑰認證搭配 runLocally:錯的公鑰被拒,指令沒有執行")
    func wrongPublicKeyIsRejected() async throws {
        let authorized = SSHPrivateKey(p256: P256.Signing.PrivateKey())
        let other = SSHPrivateKey(p256: P256.Signing.PrivateKey())
        let server = try await TestSSHServer.start(authentication: .publicKeys([try authorized.nioPublicKey()])) { _ in .runLocally }
        defer { server.stop() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint) { .privateKey(other) }

        await #expect(throws: SSHConnectionError.authenticationFailed) { _ = try await channel.execute("printf ran") }
        #expect(server.snapshot.commands.isEmpty)
    }
}
