import Foundation
import PurrdrCore
import Synchronization
import Testing

/// 主機同步的 wire(#243、#250):HTTPS 主機以 `address`(主機名稱)＋`port` 為唯一來源，不再帶 `hostServiceAddress`。
@Suite("主機同步：wire")
struct MemberSessionHostSyncTests {
    static let studio = HostConfiguration(
        id: UUID(uuidString: "6F1C2A4E-3B7D-4C8E-9A10-2B3C4D5E6F70")!, name: "Studio Mac",
        endpoint: SSHEndpoint(host: "studio-mac", username: "ray"), openSSH: .password)
    static let httpsStudio = HostConfiguration(
        id: UUID(uuidString: "1D2E3F40-5A6B-4C7D-8E9F-0A1B2C3D4E5F")!, name: "Studio HTTPS",
        hostService: HostServiceAddress("https://studio.tail1234.ts.net:8443")!)
    static let modifiedAt = Date(timeIntervalSince1970: 1_794_729_600)
    static let emptySnapshot = #"{"hosts": [], "deletedHostIds": []}"#

    /// 回固定回應的後台替身;登入用更新權杖換存取權杖。
    final class FakeBackend: BackendTransport {
        let reply: String
        private let sent = Mutex<[Data]>([])

        init(reply: String = MemberSessionHostSyncTests.emptySnapshot) {
            self.reply = reply
        }

        /// 送出的主機同步 body 的 `changes`。
        var sentChanges: [[String: Any]] {
            sent.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["changes"] as? [[String: Any]] ?? [] }
        }

        func send(_ request: BackendRequest) async throws -> BackendResponse {
            if request.path == "/v1/sessions/refresh" {
                let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
                return BackendResponse(status: 200, body: Data(#"""
                    {"accessToken": "access-1", "accessTokenExpiresAt": "\#(expiresAt)", "refreshToken": "refresh-2",
                     "member": {"id": "6f1c2b0e-5d4a-4c7e-9a7b-3e2f1d0c9b8a", "identities": []}}
                    """#.utf8))
            }
            sent.withLock { $0.append(request.body ?? Data()) }
            return BackendResponse(status: 200, body: Data(reply.utf8))
        }
    }

    func makeSession(_ backend: FakeBackend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    static func remoteHTTPS(address: String, port: Int) -> String {
        #"""
        {"hosts": [{"id": "1d2e3f40-5a6b-4c7d-8e9f-0a1b2c3d4e5f", "name": "Studio HTTPS", "address": "\#(address)", "port": \#(port),
          "username": "", "connectionMethod": "https", "hostKeyFingerprint": null, "modifiedAt": "2026-11-15T08:00:00.000Z"}],
         "deletedHostIds": []}
        """#
    }

    @Test("照常帶主機圖示")
    func sendsIcon() async throws {
        let backend = FakeBackend()
        let session = try makeSession(backend)

        _ = try await session.syncHosts([.upsert(SyncedHost(Self.studio, modifiedAt: Self.modifiedAt, icon: "macMini"))])

        #expect(backend.sentChanges.map { $0["icon"] as? String } == ["macMini"])
    }

    @Test("HTTPS 主機送主機名稱與獨立的 port,不帶 hostServiceAddress")
    func httpsHostSendsHostNameAndPort() async throws {
        let backend = FakeBackend()
        let session = try makeSession(backend)

        _ = try await session.syncHosts([.upsert(SyncedHost(Self.httpsStudio, modifiedAt: Self.modifiedAt))])

        let change = try #require(backend.sentChanges.first)
        #expect(change["address"] as? String == "studio.tail1234.ts.net")
        #expect(change["port"] as? Int == 8443)
        #expect(change.keys.contains("hostServiceAddress") == false)
    }

    @Test(
        "後台回來的 HTTPS 主機以 address＋port 組回主機服務位址",
        arguments: [
            ("studio.tail1234.ts.net", 8443, "https://studio.tail1234.ts.net:8443"),
            ("studio.tail1234.ts.net", 443, "https://studio.tail1234.ts.net"),
        ])
    func httpsHostIsRebuiltFromAddressAndPort(address: String, port: Int, expected: String) async throws {
        let backend = FakeBackend(reply: Self.remoteHTTPS(address: address, port: port))
        let session = try makeSession(backend)

        let snapshot = try await session.syncHosts([])

        #expect(snapshot.hosts.first?.hostService?.description == expected)
    }

    @Test("HTTPS 主機的 address 組不出位址：整份回應視為無效")
    func invalidHTTPSAddressIsRejected() async throws {
        let backend = FakeBackend(reply: Self.remoteHTTPS(address: "not a host", port: 443))
        let session = try makeSession(backend)

        await #expect(throws: BackendError.invalidResponse) { try await session.syncHosts([]) }
    }
}
