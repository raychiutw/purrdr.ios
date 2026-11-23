import CryptoKit
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 會員畫面 model(Seam 2:後台用 `HTTPStub` 擋在 `URLSession` 底下;Seam 3:權杖存放用記憶體內的假實作)。
///
/// 後台回應依 `raychiutw/purrdr.server` 的 `README.md` 的 API 契約手寫(後台還沒上線，錄不到真實回應)。
@MainActor
@Suite("會員")
struct MemberModelTests {
    let backend = HTTPStub()
    let google = HTTPStub()
    let tokens = InMemoryTokenStore()

    func makeModel() -> MemberModel {
        MemberModel(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            google: GoogleSignIn(
                configuration: GoogleSignIn.Configuration(
                    clientID: "123-abc.apps.googleusercontent.com",
                    authorizationEndpoint: URL(string: "https://accounts.google.test/o/oauth2/v2/auth")!,
                    tokenEndpoint: google.baseURL.appending(path: "token")
                ),
                session: google.urlSession
            )
        )
    }

    @Test("沒有登入過時是未登入狀態，不連後台")
    func startsSignedOut() async {
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .signedOut)
        #expect(backend.requests.isEmpty)
    }

    @Test("用 Sign in with Apple 登入成為會員，更新權杖存起來")
    func signInWithApple() async throws {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        let model = makeModel()
        await model.restore()

        let hashedNonce = model.beginAppleAuthorization(linking: false)
        await model.completeAppleAuthorization(idToken: "apple-id-token", authorizationCode: "apple-code")

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.notice == nil)
        let body = try #require(backend.requests(to: "/v1/sessions").first?.json)
        #expect(body["provider"] as? String == "apple")
        #expect(body["idToken"] as? String == "apple-id-token")
        #expect(body["authorizationCode"] as? String == "apple-code")
        // 交給 Apple 的是 nonce 的 SHA-256(hex),後台收到原文。
        let nonce = try #require(body["nonce"] as? String)
        #expect(sha256Hex(nonce) == hashedNonce)
        #expect(nonce.count >= 32)
        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("登入結果回報有沒有新建會員，畫面依它分流(#408)")
    func signInReportsWhetherMemberWasCreated() async {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-1", memberCreated: false, member: Replies.appleMember)))
        let model = makeModel()
        await model.restore()
        #expect(model.lastSignIn == nil)

        _ = model.beginAppleAuthorization(linking: false)
        await model.completeAppleAuthorization(idToken: "apple-id-token", authorizationCode: "apple-code")
        let first = model.lastSignIn
        #expect(first?.memberCreated == false)

        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-2", memberCreated: true, member: Replies.appleMember)))
        _ = model.beginAppleAuthorization(linking: false)
        await model.completeAppleAuthorization(idToken: "apple-id-token", authorizationCode: "apple-code")
        #expect(model.lastSignIn?.memberCreated == true)
        #expect(model.lastSignIn != first, "每次登入都是新事件，畫面才會再收到一次")
    }

    @Test("連結另一種登入方式不算登入事件")
    func linkingIsNotASignInEvent() async {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        backend.on("POST", "/v1/members/me/identities", .json(200, #"{"member": \#(Replies.googleMember), "mergedMemberId": null}"#))
        let model = makeModel()
        await model.restore()
        _ = model.beginAppleAuthorization(linking: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")
        let before = model.lastSignIn

        _ = model.beginAppleAuthorization(linking: true)
        await model.completeAppleAuthorization(idToken: "t2", authorizationCode: "c2")

        #expect(model.lastSignIn == before)
    }

    @Test("Sign in with Apple 取消時不提示也不連後台")
    func appleCanceled() async {
        let model = makeModel()
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false)
        model.appleAuthorizationFailed(canceled: true)

        #expect(model.phase == .signedOut)
        #expect(model.notice == nil)
        #expect(backend.requests.isEmpty)
    }

    @Test("用 Google 登入：PKCE 授權、向 Google 換 ID token,再交給後台")
    func signInWithGoogle() async throws {
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token", "access_token": "x", "expires_in": 3599, "token_type": "Bearer"}"#))
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-g", member: Replies.googleMember)))
        let model = makeModel()
        await model.restore()
        var opened: URLComponents?
        var scheme: String?

        await model.signInWithGoogle { url, callbackScheme in
            opened = URLComponents(url: url, resolvingAgainstBaseURL: false)
            scheme = callbackScheme
            let state = opened?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "\(callbackScheme):/oauthredirect?state=\(state)&code=google-code")!
        }

        #expect(model.phase == .signedIn(Replies.expectedGoogleMember))
        let query = try #require(opened?.queryItems).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        #expect(opened?.host == "accounts.google.test")
        #expect(query["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "com.googleusercontent.apps.123-abc:/oauthredirect")
        #expect(scheme == "com.googleusercontent.apps.123-abc")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "openid email")
        #expect(query["code_challenge_method"] == "S256")
        let exchange = try #require(google.requests(to: "/token").first).form
        #expect(exchange["code"] == "google-code")
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["redirect_uri"] == "com.googleusercontent.apps.123-abc:/oauthredirect")
        let verifier = try #require(exchange["code_verifier"])
        #expect(base64URLSHA256(verifier) == query["code_challenge"])
        let body = try #require(backend.requests(to: "/v1/sessions").first?.json)
        #expect(body["provider"] as? String == "google")
        #expect(body["idToken"] as? String == "google-id-token")
        #expect(body["nonce"] as? String == query["nonce"])
        #expect(body["authorizationCode"] == nil)
    }

    @Test("Google 登入取消時不提示也不連後台")
    func googleCanceled() async {
        let model = makeModel()
        await model.restore()

        await model.signInWithGoogle { _, _ in throw GoogleSignInError.canceled }

        #expect(model.notice == nil)
        #expect(google.requests.isEmpty)
        #expect(backend.requests.isEmpty)
    }

    @Test("Google 導回的 state 不符時不換 token(防 CSRF)")
    func googleStateMismatch() async {
        let model = makeModel()
        await model.restore()

        await model.signInWithGoogle { _, scheme in URL(string: "\(scheme):/oauthredirect?state=forged&code=c")! }

        #expect(model.phase == .signedOut)
        #expect(model.notice != nil)
        #expect(google.requests.isEmpty)
        #expect(backend.requests.isEmpty)
    }

    @Test("重新開啟 app 時用 Keychain 的更新權杖取回會員")
    func restoresStoredSignIn() async throws {
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(accessToken: "access-2", refreshToken: "refresh-2", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(backend.requests(to: "/v1/sessions/refresh").first?.json?["refreshToken"] as? String == "refresh-0")
        #expect(backend.requests(to: "/v1/members/me").first?.authorization == "Bearer access-2")
        #expect(try tokens.refreshToken() == "refresh-2")
    }

    @Test("更新權杖被拒時回到未登入並清掉 Keychain")
    func expiredSignIn() async throws {
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .json(401, Replies.error("invalid_refresh_token")))
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .signedOut)
        #expect(try tokens.refreshToken() == nil)
    }

    @Test("連不上後台時不當成登出，保留權杖並提示")
    func offlineRestore() async throws {
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .unreachable)
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .unknown)
        #expect(model.notice != nil)
        #expect(try tokens.refreshToken() == "refresh-0")
    }

    @Test("存取權杖被拒(401)時換新權杖重送一次")
    func retriesAfterRejectedAccessToken() async throws {
        let model = try await signedInModel()
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(accessToken: "access-3", refreshToken: "refresh-3", member: Replies.appleMember)))
        backend.on("DELETE", "/v1/members/me/identities/google",
                   .json(401, Replies.error("invalid_access_token")),
                   .json(200, #"{"member": \#(Replies.appleMember)}"#))

        await model.unlink(.google)

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(backend.requests(to: "/v1/members/me/identities/google").map(\.authorization) == ["Bearer access-1", "Bearer access-3"])
    }

    @Test("連結 Google 後，會員有兩種登入方式")
    func linkGoogle() async throws {
        let model = try await signedInModel()
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))
        backend.on("POST", "/v1/members/me/identities", .json(200, #"{"member": \#(Replies.linkedMember), "mergedMemberId": null}"#))

        await model.linkGoogle(browser: Self.approvingBrowser)

        guard case .signedIn(let member) = model.phase else { Issue.record("應該仍是登入狀態"); return }
        #expect(member.identities.map(\.method) == [.apple, .google])
        #expect(model.notice == nil)
        let request = try #require(backend.requests(to: "/v1/members/me/identities").first)
        #expect(request.authorization == "Bearer access-1")
        #expect(request.json?["provider"] as? String == "google")
    }

    @Test("用 Sign in with Apple 連結時帶 authorization code 給後台")
    func linkApple() async throws {
        let model = try await signedInModel()
        backend.on("POST", "/v1/members/me/identities", .json(200, #"{"member": \#(Replies.linkedMember), "mergedMemberId": null}"#))

        _ = model.beginAppleAuthorization(linking: true)
        await model.completeAppleAuthorization(idToken: "apple-2", authorizationCode: "code-2")

        let body = try #require(backend.requests(to: "/v1/members/me/identities").first?.json)
        #expect(body["provider"] as? String == "apple")
        #expect(body["authorizationCode"] as? String == "code-2")
        #expect(backend.requests(to: "/v1/sessions").isEmpty)
    }

    @Test("解除最後一種登入方式時提示至少保留一種")
    func unlinkLast() async throws {
        let model = try await signedInModel()
        backend.on("DELETE", "/v1/members/me/identities/apple", .json(409, Replies.error("last_identity")))

        await model.unlink(.apple)

        #expect(model.notice == .failed("Keep at least one sign-in method."))
        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
    }

    @Test("刪除會員後回到未登入、清掉權杖，並提醒自行取消 Apple 訂閱")
    func deleteMember() async throws {
        let model = try await signedInModel()
        backend.on("DELETE", "/v1/members/me", .empty(204))

        await model.deleteMember()

        #expect(backend.requests(to: "/v1/members/me").last?.method == "DELETE")
        #expect(backend.requests(to: "/v1/members/me").last?.authorization == "Bearer access-1")
        #expect(model.phase == .signedOut)
        #expect(model.notice == .deleted)
        #expect(try tokens.refreshToken() == nil)
    }

    @Test("Apple 撤銷失敗時會員還在，提示稍後重試")
    func deleteMemberRevokeFailed() async throws {
        let model = try await signedInModel()
        backend.on("DELETE", "/v1/members/me", .json(502, Replies.error("apple_revoke_failed")))

        await model.deleteMember()

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.notice == .failed("Couldn’t reach Apple to finish deleting. Nothing was deleted. Try again later."))
        #expect(try tokens.refreshToken() != nil)
    }

    @Test("登出時請後台作廢更新權杖，並清掉本機")
    func signOut() async throws {
        let model = try await signedInModel()
        backend.on("POST", "/v1/sessions/revoke", .empty(204))

        await model.signOut()

        #expect(backend.requests(to: "/v1/sessions/revoke").first?.json?["refreshToken"] as? String == "refresh-1")
        #expect(model.phase == .signedOut)
        #expect(try tokens.refreshToken() == nil)
    }

    /// 已用 Apple 登入的會員(存取權杖 `access-1`、更新權杖 `refresh-1`)。
    func signedInModel() async throws -> MemberModel {
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        let model = makeModel()
        await model.restore()
        try #require(model.phase == .signedIn(Replies.expectedAppleMember))
        return model
    }

    /// 假的系統瀏覽器：使用者在 Google 同意，導回 app。
    static let approvingBrowser: GoogleSignIn.Browser = { url, scheme in
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "\(scheme):/oauthredirect?state=\(state)&code=google-code")!
    }
}

func base64URLSHA256(_ text: String) -> String {
    Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// 後台回應(依 raychiutw/purrdr.server 的 README.md 的契約)。
enum Replies {
    static let appleMember = #"""
    {"id": "member-1", "identities": [{"provider": "apple", "email": "abc@privaterelay.appleid.com", "linkedAt": "2026-11-15T08:00:00.000Z"}]}
    """#

    static let expectedAppleMember = Member(
        id: "member-1",
        identities: [MemberIdentity(method: .apple, email: "abc@privaterelay.appleid.com", linkedAt: Date(timeIntervalSince1970: 1_794_729_600))]
    )

    static let googleMember = #"""
    {"id": "member-2", "identities": [{"provider": "google", "email": "cat@gmail.com", "linkedAt": "2026-11-15T08:00:00.000Z"}]}
    """#

    static let expectedGoogleMember = Member(
        id: "member-2",
        identities: [MemberIdentity(method: .google, email: "cat@gmail.com", linkedAt: Date(timeIntervalSince1970: 1_794_729_600))]
    )

    static let linkedMember = #"""
    {"id": "member-1", "identities": [
      {"provider": "apple", "email": "abc@privaterelay.appleid.com", "linkedAt": "2026-11-15T08:00:00.000Z"},
      {"provider": "google", "email": "cat@gmail.com", "linkedAt": "2026-11-15T09:00:00.000Z"}
    ]}
    """#

    static func session(accessToken: String = "access-1", expiresIn seconds: TimeInterval = 900, refreshToken: String, memberCreated: Bool = true, autoLinked: Bool = false, member: String) -> String {
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
        return #"{"accessToken": "\#(accessToken)", "accessTokenExpiresAt": "\#(expiresAt)", "refreshToken": "\#(refreshToken)", "memberCreated": \#(memberCreated), "autoLinked": \#(autoLinked), "member": \#(member)}"#
    }

    static func error(_ code: String, _ message: String = "Something happened.") -> String {
        #"{"error": {"code": "\#(code)", "message": "\#(message)"}}"#
    }
}
