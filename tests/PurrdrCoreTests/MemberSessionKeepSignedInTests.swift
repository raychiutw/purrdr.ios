import Foundation
import PurrdrCore
import Synchronization
import Testing

/// 登入保留(#406、spec #402):權杖都存本機,只有後台明確拒絕才登出,網路問題一律保留登入。
/// 後台回應依 `raychiutw/purrdr.server` 的 README(PR #29)手寫。
@Suite("會員:登入保留")
struct MemberSessionKeepSignedInTests {
    static let memberJSON = #"{"id": "member-1", "identities": [{"provider": "apple", "email": "a@example.com", "linkedAt": "2026-11-15T08:00:00.000Z"}]}"#

    /// 依序回放預先排好的結果(回應或錯誤)的後台替身,記錄送出的請求。
    final class ScriptedBackend: BackendTransport {
        enum Step {
            case reply(Int, String)
            case fail(any Error)
        }

        private let steps = Mutex<[String: [Step]]>([:])
        private let sent = Mutex<[BackendRequest]>([])

        func on(_ method: String, _ path: String, _ replies: Step...) {
            steps.withLock { $0["\(method) \(path)"] = replies }
        }

        var requests: [BackendRequest] { sent.withLock { $0 } }
        func requests(to path: String) -> [BackendRequest] { requests.filter { $0.path == path } }

        func send(_ request: BackendRequest) async throws -> BackendResponse {
            sent.withLock { $0.append(request) }
            let step = steps.withLock { steps -> Step? in
                let key = "\(request.method) \(request.path)"
                guard var queue = steps[key], let first = queue.first else { return nil }
                if queue.count > 1 { queue.removeFirst(); steps[key] = queue }
                return first
            }
            switch step {
            case .reply(let status, let body): return BackendResponse(status: status, body: Data(body.utf8))
            case .fail(let error): throw error
            case nil: return BackendResponse(status: 404, body: Data(#"{"error":{"code":"not_found","message":""}}"#.utf8))
            }
        }
    }

    /// 寫入可以指定失敗的權杖存放(檢查「寫新失敗不會丟掉舊的」)。
    final class FlakyTokenStore: TokenStore {
        let base = InMemoryTokenStore()
        let failsWrites = Mutex(false)

        struct WriteFailed: Error {}

        func refreshToken() throws -> String? { try base.refreshToken() }
        func setRefreshToken(_ token: String?) throws {
            if failsWrites.withLock({ $0 }), token != nil { throw WriteFailed() }
            try base.setRefreshToken(token)
        }
        func accessToken() throws -> StoredAccessToken? { try base.accessToken() }
        func setAccessToken(_ token: StoredAccessToken?) throws {
            if failsWrites.withLock({ $0 }), token != nil { throw WriteFailed() }
            try base.setAccessToken(token)
        }
        func memberSnapshot() throws -> Data? { try base.memberSnapshot() }
        func setMemberSnapshot(_ snapshot: Data?) throws { try base.setMemberSnapshot(snapshot) }
    }

    static func session(
        accessToken: String = "access-2", refreshToken: String = "refresh-2", expiresIn seconds: TimeInterval = 900
    ) -> String {
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
        return #"{"accessToken": "\#(accessToken)", "accessTokenExpiresAt": "\#(expiresAt)", "refreshToken": "\#(refreshToken)", "member": \#(memberJSON)}"#
    }

    static func error(_ code: String) -> String { #"{"error": {"code": "\#(code)", "message": "x"}}"# }

    // MARK: - 只有明確拒絕才登出

    @Test("連不上後台:不登出,更新權杖與會員快照都留著")
    func networkErrorKeepsSignIn() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .fail(URLError(.notConnectedToInternet)))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        let session = MemberSession(transport: backend, tokenStore: tokens)

        await #expect(throws: BackendError.unreachable) { try await session.currentMember() }

        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("逾時:不登出,更新權杖留著")
    func timeoutKeepsSignIn() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .fail(URLError(.timedOut)))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        let session = MemberSession(transport: backend, tokenStore: tokens)

        await #expect(throws: BackendError.unreachable) { try await session.currentMember() }

        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("後台 5xx:不登出")
    func serverErrorKeepsSignIn() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(503, Self.error("unavailable")))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        let session = MemberSession(transport: backend, tokenStore: tokens)

        await #expect(throws: BackendError.self) { try await session.currentMember() }

        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("401 但不是工作階段被撤銷(不認得的錯誤碼):不登出")
    func otherUnauthorizedKeepsSignIn() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(401, Self.error("something_else")))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        let session = MemberSession(transport: backend, tokenStore: tokens)

        await #expect(throws: BackendError.self) { try await session.currentMember() }

        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("後台明確拒絕更新權杖(invalid_refresh_token):登出並清掉本機的權杖與快照")
    func explicitRejectionSignsOut() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(401, Self.error("invalid_refresh_token")))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        try tokens.setAccessToken(StoredAccessToken(token: "old", expiresAt: Date().addingTimeInterval(-10)))
        try tokens.setMemberSnapshot(Data("{}".utf8))
        let session = MemberSession(transport: backend, tokenStore: tokens)

        await #expect(throws: BackendError.signedOut) { try await session.currentMember() }

        #expect(try tokens.refreshToken() == nil)
        #expect(try tokens.accessToken() == nil)
        #expect(try tokens.memberSnapshot() == nil)
    }

    // MARK: - 重開 app

    @Test("重開 app:存取權杖還有效就直接用,不必先換權杖")
    func restartReusesStoredAccessToken() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions", .reply(200, Self.session(accessToken: "access-1", refreshToken: "refresh-1")))
        backend.on("GET", "/v1/members/me", .reply(200, #"{"member": \#(Self.memberJSON)}"#))
        let tokens = InMemoryTokenStore()
        let first = MemberSession(transport: backend, tokenStore: tokens)
        _ = try await first.signIn(SignInCredential(method: .apple, idToken: "t", nonce: "n", authorizationCode: "c"))

        // 模擬冷啟動:新的 MemberSession,同一份本機存放。
        let second = MemberSession(transport: backend, tokenStore: tokens)
        let member = try await second.currentMember()

        #expect(member?.id == "member-1")
        #expect(backend.requests(to: "/v1/sessions/refresh").isEmpty)
        #expect(backend.requests(to: "/v1/members/me").first?.accessToken == "access-1")
    }

    @Test("重開 app:存取權杖過期了就用更新權杖換,換到的新權杖存起來")
    func restartRenewsExpiredAccessToken() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(200, Self.session(accessToken: "access-2", refreshToken: "refresh-2")))
        backend.on("GET", "/v1/members/me", .reply(200, #"{"member": \#(Self.memberJSON)}"#))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        try tokens.setAccessToken(StoredAccessToken(token: "access-old", expiresAt: Date().addingTimeInterval(-60)))
        let session = MemberSession(transport: backend, tokenStore: tokens)

        _ = try await session.currentMember()

        #expect(try tokens.refreshToken() == "refresh-2")
        #expect(try tokens.accessToken()?.token == "access-2")
    }

    @Test("讀到會員後留下快照;沒有網路時可由快照知道目前登入的會員")
    func memberSnapshotSurvivesOffline() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(200, Self.session()))
        backend.on("GET", "/v1/members/me", .reply(200, #"{"member": \#(Self.memberJSON)}"#))
        let tokens = InMemoryTokenStore(refreshToken: "refresh-1")
        _ = try await MemberSession(transport: backend, tokenStore: tokens).currentMember()

        let offline = MemberSession(transport: ScriptedBackend(), tokenStore: tokens)
        let cached = try await offline.cachedMember()

        #expect(cached?.id == "member-1")
        #expect(cached?.identities.first?.email == "a@example.com")
    }

    @Test("登入成功就留下會員快照:剛登入後冷啟動又離線,仍由快照知道是誰(#406)")
    func signInRemembersMemberSnapshot() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions", .reply(200, Self.session()))
        let tokens = InMemoryTokenStore()
        _ = try await MemberSession(transport: backend, tokenStore: tokens)
            .signIn(SignInCredential(method: .apple, idToken: "t", nonce: "n", authorizationCode: "c"))

        let offline = MemberSession(transport: ScriptedBackend(), tokenStore: tokens)
        let cached = try await offline.cachedMember()

        #expect(cached?.id == "member-1")
    }

    // MARK: - 寫入順序

    @Test("換權杖時寫入新權杖失敗:舊的更新權杖與存取權杖都不會被刪掉")
    func failedWriteKeepsPreviousTokens() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(200, Self.session(accessToken: "access-2", refreshToken: "refresh-2")))
        let tokens = FlakyTokenStore()
        try tokens.setRefreshToken("refresh-1")
        try tokens.setAccessToken(StoredAccessToken(token: "access-1", expiresAt: Date().addingTimeInterval(-60)))
        tokens.failsWrites.withLock { $0 = true }
        let session = MemberSession(transport: backend, tokenStore: tokens)

        await #expect(throws: (any Error).self) { try await session.currentMember() }

        #expect(try tokens.refreshToken() == "refresh-1")
        #expect(try tokens.accessToken()?.token == "access-1")
    }

    // MARK: - 這支裝置

    @Test("登入帶這支裝置的 id(小寫 UUID)與平台")
    func signInSendsDeviceAndPlatform() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions", .reply(200, Self.session(accessToken: "a", refreshToken: "r")))
        let session = MemberSession(
            transport: backend, tokenStore: InMemoryTokenStore(), deviceID: { "5EED0000-0000-4000-8000-0000000000D1" })

        _ = try await session.signIn(SignInCredential(method: .google, idToken: "t", nonce: "n"))

        let body = try #require(backend.requests(to: "/v1/sessions").first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["deviceId"] as? String == "5eed0000-0000-4000-8000-0000000000d1")
        #expect(json["platform"] as? String == "ios")
    }

    @Test("讀不到這支裝置的 id 時照常登入,不帶 deviceId")
    func signInWithoutDeviceID() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions", .reply(200, Self.session(accessToken: "a", refreshToken: "r")))
        let session = MemberSession(transport: backend, tokenStore: InMemoryTokenStore(), deviceID: { nil })

        _ = try await session.signIn(SignInCredential(method: .google, idToken: "t", nonce: "n"))

        let body = try #require(backend.requests(to: "/v1/sessions").first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["deviceId"] == nil)
        #expect(json["platform"] as? String == "ios")
    }

    // MARK: - 診斷

    @Test("診斷只記結果碼,不含 email 與權杖")
    func diagnosticsHaveResultCodesOnly() async throws {
        let backend = ScriptedBackend()
        backend.on("POST", "/v1/sessions/refresh", .reply(401, Self.error("invalid_refresh_token")))
        let events = Mutex<[MemberDiagnosticEvent]>([])
        let session = MemberSession(
            transport: backend, tokenStore: InMemoryTokenStore(refreshToken: "refresh-secret"),
            diagnostics: { event in events.withLock { $0.append(event) } })

        _ = try? await session.currentMember()

        let recorded = events.withLock { $0 }
        #expect(recorded.contains(.refreshRejected(code: "invalid_refresh_token")))
        #expect(!recorded.map { "\($0)" }.joined().contains("refresh-secret"))
    }
}
