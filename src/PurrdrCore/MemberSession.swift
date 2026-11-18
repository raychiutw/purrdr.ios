import Foundation

/// 與 Purrdr 後台的會員連線：登入、權杖管理、會員操作。
///
/// - 更新權杖存在 `TokenStore`(iOS 是 Keychain),存取權杖只放記憶體。
/// - 存取權杖快過期或被後台拒絕(401)時，自動用更新權杖換一組新的再重送一次;同時間只會有一個換權杖的請求
///   (更新權杖用一次就作廢，兩個同時換會讓其中一個失效)。
/// - 更新權杖被拒時清掉本機的登入狀態，丟 `BackendError.signedOut`。
/// - wire format(camelCase JSON)只在這個檔案處理，契約見 `backend/README.md`。
public actor MemberSession {
    public struct SignInResult: Sendable, Equatable {
        public var member: Member
        /// 這次登入是否新建了會員。
        public var memberCreated: Bool
    }

    public struct LinkResult: Sendable, Equatable {
        public var member: Member
        /// 連結時併入並刪除的空會員 ID;沒有合併時是 `nil`。
        public var mergedMemberID: String?
    }

    /// 存取權杖剩下不到這麼久就先換新的，避免送出途中過期。
    static let accessTokenRenewalMargin: TimeInterval = 30

    private let transport: any BackendTransport
    private let tokenStore: any TokenStore
    private let now: @Sendable () -> Date
    private var accessToken: (token: String, expiresAt: Date)?
    private var renewal: Task<Member, any Error>?

    public init(transport: any BackendTransport, tokenStore: any TokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.now = now
    }

    /// 用 Apple 或 Google 的憑證登入;沒有會員時後台會建立一個。
    public func signIn(_ credential: SignInCredential) async throws -> SignInResult {
        let response = try await send(BackendRequest(method: "POST", path: "/v1/sessions", body: try Wire.encode(credential)))
        let session = try Wire.decode(Wire.Session.self, from: response)
        try adopt(session)
        return SignInResult(member: try session.member.domain(), memberCreated: session.memberCreated ?? false)
    }

    /// 目前登入的會員;沒有登入過時回傳 `nil`。登入已失效時丟 `BackendError.signedOut`。
    public func currentMember() async throws -> Member? {
        guard try tokenStore.refreshToken() != nil else { return nil }
        let response = try await authorized(BackendRequest(method: "GET", path: "/v1/members/me"))
        return try Wire.decode(Wire.MemberEnvelope.self, from: response).member.domain()
    }

    /// 連結另一種登入方式。
    public func link(_ credential: SignInCredential) async throws -> LinkResult {
        let response = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/identities", body: try Wire.encode(credential)))
        let link = try Wire.decode(Wire.Link.self, from: response)
        return LinkResult(member: try link.member.domain(), mergedMemberID: link.mergedMemberId)
    }

    /// 解除連結(後台要求至少保留一種)。
    public func unlink(_ method: SignInMethod) async throws -> Member {
        let response = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me/identities/\(method.rawValue)"))
        return try Wire.decode(Wire.MemberEnvelope.self, from: response).member.domain()
    }

    /// 刪除會員：後台撤銷 Sign in with Apple 權杖並刪除所有資料;成功後清掉本機的登入狀態。
    public func deleteMember() async throws {
        _ = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me"))
        try clear()
    }

    /// 登出：請後台作廢更新權杖(盡力而為)並清掉本機的登入狀態。
    public func signOut() async throws {
        if let refreshToken = try tokenStore.refreshToken() {
            let body = try JSONEncoder().encode(["refreshToken": refreshToken])
            _ = try? await transport.send(BackendRequest(method: "POST", path: "/v1/sessions/revoke", body: body))
        }
        try clear()
    }

    // MARK: - 訂閱(Purrdr Plus)

    /// 會員目前的訂閱;從來沒訂閱過是 `nil`。沒有登入時丟 `BackendError.signedOut`。
    public func subscription() async throws -> MemberSubscription? {
        let response = try await authorized(BackendRequest(method: "GET", path: "/v1/members/me/subscription"))
        return try Wire.decode(Wire.SubscriptionEnvelope.self, from: response).subscription?.domain()
    }

    /// 把 StoreKit 2 的簽章交易(JWS)交給後台驗證並記到會員身上，回傳更新後的訂閱。
    public func submitAppStoreTransaction(_ signedTransaction: String) async throws -> MemberSubscription? {
        let body = try JSONEncoder().encode(["signedTransaction": signedTransaction])
        let response = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/subscription/app-store", body: body))
        return try Wire.decode(Wire.SubscriptionEnvelope.self, from: response).subscription?.domain()
    }

    // MARK: - 主機同步

    /// 主機同步(要有效的 Purrdr Plus):送出這支裝置的變更，回傳後台套用後的整份清單與刪除紀錄。
    /// 只送 `SyncedHost` 的欄位(白名單);沒有訂閱時後台回 403 `subscription_required`。
    public func syncHosts(_ changes: [HostSyncChange]) async throws -> HostSyncSnapshot {
        let body = try JSONEncoder().encode(Wire.HostSyncRequest(changes: changes.map(Wire.HostChange.init)))
        let response = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/hosts/sync", body: body))
        return try Wire.decode(Wire.HostSyncResponse.self, from: response).domain()
    }

    // MARK: - 推播配對(#29)

    /// APNs 的環境：App Store／TestFlight 是 production,Xcode 直接安裝的 Debug build 是 sandbox。
    public enum PushEnvironment: String, Sendable {
        case production
        case sandbox
    }

    /// 向後台註冊(或更新 device token)一組推播配對。只送配對密鑰的**雜湊**,密鑰本身不離開 app 與主機。
    /// 需要有效訂閱(否則 403 `subscription_required`)。
    public func registerPushPairing(keyHash: String, deviceToken: String, environment: PushEnvironment) async throws {
        let body = try JSONEncoder().encode([
            "keyHash": keyHash, "platform": "apns", "deviceToken": deviceToken, "environment": environment.rawValue,
        ])
        _ = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/push-pairings", body: body))
    }

    /// 撤銷推播配對(只撤銷自己的;不存在也算成功)。
    public func revokePushPairing(keyHash: String) async throws {
        _ = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me/push-pairings/\(keyHash)"))
    }

    // MARK: - 權杖

    private func authorized(_ request: BackendRequest) async throws -> BackendResponse {
        var request = request
        request.accessToken = try await validAccessToken()
        do {
            return try await send(request)
        } catch let BackendError.backend(status, _, _) where status == 401 {
            accessToken = nil
            request.accessToken = try await validAccessToken()
            return try await send(request)
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expiresAt.timeIntervalSince(now()) > Self.accessTokenRenewalMargin {
            return accessToken.token
        }
        _ = try await renew()
        guard let accessToken else { throw BackendError.signedOut }
        return accessToken.token
    }

    /// 用更新權杖換一組新的權杖;同時間只送一個。
    private func renew() async throws -> Member {
        if let renewal { return try await renewal.value }
        let task = Task { try await self.performRenewal() }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    private func performRenewal() async throws -> Member {
        guard let refreshToken = try tokenStore.refreshToken() else { throw BackendError.signedOut }
        let body = try JSONEncoder().encode(["refreshToken": refreshToken])
        do {
            let response = try await send(BackendRequest(method: "POST", path: "/v1/sessions/refresh", body: body))
            let session = try Wire.decode(Wire.Session.self, from: response)
            try adopt(session)
            return try session.member.domain()
        } catch let BackendError.backend(status, _, _) where status == 401 {
            try clear()
            throw BackendError.signedOut
        }
    }

    private func adopt(_ session: Wire.Session) throws {
        guard let expiresAt = Wire.date(session.accessTokenExpiresAt) else { throw BackendError.invalidResponse }
        try tokenStore.setRefreshToken(session.refreshToken)
        accessToken = (session.accessToken, expiresAt)
    }

    private func clear() throws {
        accessToken = nil
        try tokenStore.setRefreshToken(nil)
    }

    /// 送出請求;非 2xx 轉成 `BackendError.backend`,傳輸層的錯誤一律是 `.unreachable`。
    private func send(_ request: BackendRequest) async throws -> BackendResponse {
        let response: BackendResponse
        do {
            response = try await transport.send(request)
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.unreachable
        }
        guard (200..<300).contains(response.status) else {
            guard let envelope = try? JSONDecoder().decode(Wire.ErrorEnvelope.self, from: response.body) else {
                throw BackendError.backend(status: response.status, code: "unknown", message: "")
            }
            throw BackendError.backend(status: response.status, code: envelope.error.code, message: envelope.error.message)
        }
        return response
    }
}

/// 後台 JSON 的形狀(backend/README.md)。
private enum Wire {
    struct Credential: Encodable {
        var provider: String
        var idToken: String
        var nonce: String
        var authorizationCode: String?
    }

    struct Session: Decodable {
        var accessToken: String
        var accessTokenExpiresAt: String
        var refreshToken: String
        var memberCreated: Bool?
        var member: MemberBody
    }

    struct MemberEnvelope: Decodable {
        var member: MemberBody
    }

    struct Link: Decodable {
        var member: MemberBody
        var mergedMemberId: String?
    }

    struct MemberBody: Decodable {
        var id: String
        var identities: [Identity]

        struct Identity: Decodable {
            var provider: String
            var email: String?
            var linkedAt: String
        }

        func domain() throws -> Member {
            let identities = try identities.compactMap { identity -> MemberIdentity? in
                // 不認得的登入方式(例如之後新增的)先略過，不讓整個會員讀取失敗。
                guard let method = SignInMethod(rawValue: identity.provider) else { return nil }
                guard let linkedAt = Wire.date(identity.linkedAt) else { throw BackendError.invalidResponse }
                return MemberIdentity(method: method, email: identity.email, linkedAt: linkedAt)
            }
            return Member(id: id, identities: identities)
        }
    }

    struct SubscriptionEnvelope: Decodable {
        var subscription: SubscriptionBody?
    }

    struct SubscriptionBody: Decodable {
        var status: String
        var store: String
        var productId: String
        var expiresAt: String
        var gracePeriodExpiresAt: String?
        var willAutoRenew: Bool?

        func domain() throws -> MemberSubscription {
            guard let status = MemberSubscription.Status(rawValue: status),
                  let store = MemberSubscription.Store(rawValue: store),
                  let expiresAt = Wire.date(expiresAt)
            else { throw BackendError.invalidResponse }
            return MemberSubscription(
                status: status, store: store, productID: productId, expiresAt: expiresAt,
                gracePeriodExpiresAt: gracePeriodExpiresAt.flatMap(Wire.date), willAutoRenew: willAutoRenew
            )
        }
    }

    // MARK: 主機同步

    struct HostSyncRequest: Encodable {
        var changes: [HostChange]
        /// 這支 app 看得懂的連線方式;沒帶的舊版 app 後台不回 HTTPS 主機。
        var connectionMethods = ["tailscale_ssh", "openssh", "https"]
    }

    /// 送出的一筆變更。欄位白名單(後台也只收這些):私鑰、密碼、裝置權杖、登入方式、herdr 設定不在這裡。
    enum HostChange: Encodable {
        case upsert(HostBody)
        case delete(Deletion)

        init(_ change: HostSyncChange) {
            switch change {
            case .upsert(let host): self = .upsert(HostBody(host))
            case .delete(let id): self = .delete(Deletion(id: id.uuidString, deleted: true))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .upsert(let body): try body.encode(to: encoder)
            case .delete(let deletion): try deletion.encode(to: encoder)
            }
        }
    }

    struct Deletion: Encodable {
        var id: String
        var deleted: Bool
    }

    struct HostBody: Codable {
        var id: String
        var name: String
        var address: String
        var port: Int
        var username: String
        var connectionMethod: String
        var hostKeyFingerprint: String?
        /// 只有 HTTPS 主機有。
        var hostServiceAddress: String?
        var modifiedAt: String

        init(_ host: SyncedHost) {
            id = host.id.uuidString
            name = host.name
            address = host.endpoint.host
            port = host.endpoint.port
            username = host.endpoint.username
            connectionMethod = switch host.connectionMethod {
            case .openSSH: "openssh"
            case .tailscaleSSH: "tailscale_ssh"
            case .https: "https"
            }
            hostKeyFingerprint = host.hostKeyPin?.stored
            hostServiceAddress = host.hostService?.description
            modifiedAt = host.modifiedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }

        /// 明確寫出 `null`(沒有指紋)。
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(address, forKey: .address)
            try container.encode(port, forKey: .port)
            try container.encode(username, forKey: .username)
            try container.encode(connectionMethod, forKey: .connectionMethod)
            try container.encode(hostKeyFingerprint, forKey: .hostKeyFingerprint)
            try container.encodeIfPresent(hostServiceAddress, forKey: .hostServiceAddress)
            try container.encode(modifiedAt, forKey: .modifiedAt)
        }

        func domain() throws -> SyncedHost {
            let method: HostConfiguration.ConnectionMethod
            switch connectionMethod {
            case "openssh": method = .openSSH
            case "tailscale_ssh": method = .tailscaleSSH
            case "https": method = .https
            default: throw BackendError.invalidResponse
            }
            let hostService = hostServiceAddress.flatMap(HostServiceAddress.init)
            if method == .https, hostService == nil { throw BackendError.invalidResponse }
            guard let id = UUID(uuidString: id), let modifiedAt = Wire.date(modifiedAt) else { throw BackendError.invalidResponse }
            return SyncedHost(
                id: id, name: name, endpoint: SSHEndpoint(host: address, port: port, username: username), connectionMethod: method,
                hostKeyPin: hostKeyFingerprint.flatMap(HostKeyFingerprint.init(stored:)),
                hostService: hostService, modifiedAt: modifiedAt)
        }
    }

    struct HostSyncResponse: Decodable {
        var hosts: [HostBody]
        var deletedHostIds: [String]

        func domain() throws -> HostSyncSnapshot {
            HostSyncSnapshot(
                hosts: try hosts.map { try $0.domain() },
                deletedHostIDs: try deletedHostIds.map { text in
                    guard let id = UUID(uuidString: text) else { throw BackendError.invalidResponse }
                    return id
                })
        }
    }

    struct ErrorEnvelope: Decodable {
        var error: Body

        struct Body: Decodable {
            var code: String
            var message: String
        }
    }

    static func encode(_ credential: SignInCredential) throws -> Data {
        try JSONEncoder().encode(Credential(
            provider: credential.method.rawValue,
            idToken: credential.idToken,
            nonce: credential.nonce,
            authorizationCode: credential.authorizationCode
        ))
    }

    static func decode<T: Decodable>(_ type: T.Type, from response: BackendResponse) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    /// 後台的時間是 JavaScript `toISOString()`(含毫秒)。
    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
