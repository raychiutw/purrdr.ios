import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 主機服務回重新導向時，裝置權杖不能被帶到別的主機(#574)。
///
/// 原主機在 `127.0.0.1`,導向的目標是另一個假主機服務的 `localhost`(主機名稱不同)。
@Suite("主機服務的重新導向")
struct HostServiceRedirectTests {
    @Test("撤銷權杖遇到導向別的主機：不跟隨，權杖不送到目標")
    func revokeRedirectIsNotFollowed() async throws {
        let target = try await FakeHostService.start()
        defer { Task { await target.stop() } }
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        service.update { $0.revokeRedirectLocation = "http://localhost:\(target.port)/v1/revoke" }

        let response = try await URLSessionHostServiceTransport()
            .post(service.address.revokeURL, bearerToken: "token-ok", body: nil)

        #expect(!target.log.revokeAuthorizations.contains("Bearer token-ok"))
        #expect(target.log.revokeAuthorizations.isEmpty)
        #expect(response.status == 307)
    }

    @Test("WebSocket 握手遇到導向別的主機：不跟隨，權杖不送到目標")
    func webSocketRedirectIsNotFollowed() async throws {
        // 目標拒絕任何權杖並關閉連線，跟隨導向時 `receive()` 也會結束。
        let target = try await FakeHostService.start(.init(validTokens: []))
        defer { Task { await target.stop() } }
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        service.update { $0.webSocketRedirectLocation = "ws://localhost:\(target.port)/v1/ws" }

        let socket = try? await URLSessionHostServiceTransport(timeout: 5)
            .connect(to: service.address.webSocketURL, bearerToken: "token-ok")
        _ = try? await socket?.receive()
        await socket?.close()

        #expect(!target.log.authorizations.contains("Bearer token-ok"))
        #expect(target.log.connections == 0)
    }
}
