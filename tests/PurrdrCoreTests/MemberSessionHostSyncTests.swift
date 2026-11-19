import Foundation
import PurrdrCore
import Synchronization
import Testing

/// 主機同步的 wire 相容(#243):還沒部署圖示欄位的舊後台遇到 `icon` 會整個請求 400,app 要改送不含圖示的版本。
@Suite("主機同步：舊後台相容")
struct MemberSessionHostSyncTests {
    static let studio = HostConfiguration(
        id: UUID(uuidString: "6F1C2A4E-3B7D-4C8E-9A10-2B3C4D5E6F70")!, name: "Studio Mac",
        endpoint: SSHEndpoint(host: "studio-mac", username: "ray"), openSSH: .password)
    static let modifiedAt = Date(timeIntervalSince1970: 1_794_729_600)
    static let snapshot = #"{"hosts": [], "deletedHostIds": []}"#

    /// 舊後台(#243 之前)對帶 `icon` 的修改實際回的錯誤(以舊版 backend/src/host-sync.ts 實測)。
    static let oldBackendRejection = #"{"error":{"code":"invalid_request","message":"Unexpected field: icon."}}"#

    /// 依後台版本回應主機同步的替身;登入用更新權杖換存取權杖。
    final class FakeBackend: BackendTransport {
        let acceptsIcon: Bool
        let rejection: String
        private let sent = Mutex<[Data]>([])

        init(acceptsIcon: Bool, rejection: String = MemberSessionHostSyncTests.oldBackendRejection) {
            self.acceptsIcon = acceptsIcon
            self.rejection = rejection
        }

        /// 送出的主機同步 body。
        var syncBodies: [[String: Any]] {
            sent.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        func send(_ request: BackendRequest) async throws -> BackendResponse {
            if request.path == "/v1/sessions/refresh" {
                let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
                return BackendResponse(status: 200, body: Data(#"""
                    {"accessToken": "access-1", "accessTokenExpiresAt": "\#(expiresAt)", "refreshToken": "refresh-2",
                     "member": {"id": "6f1c2b0e-5d4a-4c7e-9a7b-3e2f1d0c9b8a", "identities": []}}
                    """#.utf8))
            }
            let body = request.body ?? Data()
            sent.withLock { $0.append(body) }
            if !acceptsIcon, String(decoding: body, as: UTF8.self).contains(#""icon""#) {
                return BackendResponse(status: 400, body: Data(rejection.utf8))
            }
            return BackendResponse(status: 200, body: Data(MemberSessionHostSyncTests.snapshot.utf8))
        }
    }

    func makeSession(_ backend: FakeBackend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    static func changes(icon: String? = "macMini") -> [HostSyncChange] {
        [.upsert(SyncedHost(studio, modifiedAt: modifiedAt, icon: icon))]
    }

    static func sentIcons(_ body: [String: Any]) -> [String?] {
        (body["changes"] as? [[String: Any]] ?? []).map { $0["icon"] as? String }
    }

    @Test("新後台：照常帶主機圖示")
    func newBackendReceivesIcon() async throws {
        let backend = FakeBackend(acceptsIcon: true)
        let session = try makeSession(backend)

        _ = try await session.syncHosts(Self.changes())

        #expect(backend.syncBodies.map(Self.sentIcons) == [["macMini"]])
    }

    @Test("舊後台拒絕 icon:同一次同步改送不含圖示的版本，其他欄位照常同步成功")
    func oldBackendRetriesWithoutIcon() async throws {
        let backend = FakeBackend(acceptsIcon: false)
        let session = try makeSession(backend)

        let snapshot = try await session.syncHosts(Self.changes())

        #expect(snapshot == HostSyncSnapshot(hosts: [], deletedHostIDs: []))
        #expect(backend.syncBodies.map(Self.sentIcons) == [["macMini"], [nil]])
        let retried = try #require((backend.syncBodies.last?["changes"] as? [[String: Any]])?.first)
        #expect(retried["name"] as? String == "Studio Mac")
        #expect(retried.keys.contains("icon") == false)
    }

    @Test("記住舊後台不支援圖示：之後的同步(這次執行內)直接不帶，不再先被拒")
    func rememberedForLaterSyncs() async throws {
        let backend = FakeBackend(acceptsIcon: false)
        let session = try makeSession(backend)
        _ = try await session.syncHosts(Self.changes())

        _ = try await session.syncHosts(Self.changes(icon: "rack"))

        #expect(backend.syncBodies.map(Self.sentIcons) == [["macMini"], [nil], [nil]])
    }

    @Test("其他欄位被拒(不是圖示):不重送，照常丟錯")
    func otherRejectionIsNotRetried() async throws {
        let backend = FakeBackend(
            acceptsIcon: false, rejection: #"{"error":{"code":"invalid_request","message":"name must be 1–100 characters."}}"#)
        let session = try makeSession(backend)

        await #expect(throws: BackendError.backend(status: 400, code: "invalid_request", message: "name must be 1–100 characters.")) {
            try await session.syncHosts(Self.changes())
        }
        #expect(backend.syncBodies.count == 1)
    }
}
