import Foundation

/// 與 Purrdr 後台的會員連線：登入、權杖管理、會員操作。
///
/// - 存取權杖與更新權杖都存在 `TokenStore`(iOS 是 Keychain),重開 app 不必先換權杖(#406)。
///   換到新權杖時先寫新的(更新權杖優先)、成功才換掉記憶體;寫入失敗不動舊的,60 秒內重送舊更新權杖會拿回同一組新權杖。
/// - 存取權杖快過期或被後台拒絕(401)時，自動用更新權杖換一組新的再重送一次;同時間只會有一個換權杖的請求。
/// - **只有後台明確拒絕**(401 `invalid_refresh_token`:工作階段被撤銷、過期或重用舊權杖)才清掉本機的登入狀態、丟 `BackendError.signedOut`;
///   連不上、逾時、5xx 與其他錯誤都保留登入(丟 `.unreachable` 或 `.backend`)。
/// - wire format(camelCase JSON)只在這個檔案處理，契約見 `raychiutw/purrdr.server` 的 `README.md`。
public actor MemberSession {
    public struct SignInResult: Sendable, Equatable {
        public var member: Member
        /// 這次登入是否新建了會員。
        public var memberCreated: Bool
        /// 新身分的已驗證 email 與既有會員相同,後台自動歸到那個會員(`autoLinked`)。
        public var autoLinked: Bool = false
    }

    public struct LinkResult: Sendable, Equatable {
        public var member: Member
    }

    public struct MergeResult: Sendable, Equatable {
        /// 留下的會員(可能是對方,不一定是原本登入的那個)。
        public var member: Member
        /// 被刪除的會員 ID。
        public var mergedMemberID: String
    }

    /// 存取權杖剩下不到這麼久就先換新的，避免送出途中過期。
    static let accessTokenRenewalMargin: TimeInterval = 30

    private let transport: any BackendTransport
    private let tokenStore: any TokenStore
    private let now: @Sendable () -> Date
    private let deviceID: @Sendable () -> String?
    private let diagnostics: MemberDiagnostics
    private let supportsSignInOnly: Bool
    private var accessToken: (token: String, expiresAt: Date)?
    private var renewal: Task<Member, any Error>?

    /// - Parameters:
    ///   - deviceID: 這支裝置在後台的 id(app 存在 Keychain 的 UUID);登入時帶上,讓後台一支裝置只留一個工作階段。讀不到時回 `nil`,照常登入。
    ///   - diagnostics: 診斷事件(只有結果碼,不含個資)。
    ///   - supportsSignInOnly: 後台是否有「登入不新建會員」選項(`createMember: false`,查無會員回 404 `member_not_found`,#434)。
    ///     後台已上線(purrdr.server#34),composition root 開啟;預設 `false`:登入照舊(查無會員會新建)。
    public init(
        transport: any BackendTransport, tokenStore: any TokenStore, now: @escaping @Sendable () -> Date = { Date() },
        deviceID: @escaping @Sendable () -> String? = { nil }, diagnostics: @escaping MemberDiagnostics = { _ in },
        supportsSignInOnly: Bool = false
    ) {
        self.supportsSignInOnly = supportsSignInOnly
        self.transport = transport
        self.tokenStore = tokenStore
        self.now = now
        self.deviceID = deviceID
        self.diagnostics = diagnostics
    }

    /// 本機留著的會員快照(上次成功讀到的);沒有登入或沒有快照是 `nil`。不連後台。
    public func cachedMember() throws -> Member? {
        guard try tokenStore.refreshToken() != nil, let data = try tokenStore.memberSnapshot() else { return nil }
        return try? JSONDecoder().decode(Wire.MemberBody.self, from: data).domain()
    }

    /// 用 Apple 或 Google 的憑證登入;沒有會員時後台會建立一個。
    /// `createIfMissing` 為 `false`(登入頁)且後台支援時,查無會員不新建、丟 `BackendError.backend(404, "member_not_found")`;
    /// 後台不支援時這個參數不生效(不送,避免先建後擋留下孤兒會員)。
    public func signIn(_ credential: SignInCredential, createIfMissing: Bool = true) async throws -> SignInResult {
        let createMember: Bool? = (!createIfMissing && supportsSignInOnly) ? false : nil
        let response = try await send(BackendRequest(
            method: "POST", path: "/v1/sessions",
            body: try Wire.encode(credential, deviceID: deviceID()?.lowercased(), isSignIn: true, createMember: createMember)))
        let session = try Wire.decode(Wire.Session.self, from: response)
        try adopt(session)
        diagnostics(.signedIn)
        return SignInResult(member: try session.member.domain(), memberCreated: session.memberCreated ?? false, autoLinked: session.autoLinked ?? false)
    }

    /// 目前登入的會員;沒有登入過時回傳 `nil`。登入已失效時丟 `BackendError.signedOut`。
    public func currentMember() async throws -> Member? {
        guard try tokenStore.refreshToken() != nil else { return nil }
        let response = try await authorized(BackendRequest(method: "GET", path: "/v1/members/me"))
        let body = try Wire.decode(Wire.MemberEnvelope.self, from: response).member
        remember(body)
        return try body.domain()
    }

    /// 連結另一種登入方式。身分已屬於另一個會員時丟 `BackendError.mergeRequired`(附兩邊摘要),不會合併。
    public func link(_ credential: SignInCredential) async throws -> LinkResult {
        let response = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/identities", body: try Wire.encode(credential)))
        let link = try Wire.decode(Wire.Link.self, from: response)
        remember(link.member)
        return LinkResult(member: try link.member.domain())
    }

    /// 確認合併(呼叫端先要求裝置擁有者驗證;憑證要重新帶,同連結)。
    /// 留下的可能是對方會員,原本的存取權杖屬於被刪的會員,所以換上回應附的新存取權杖(更新權杖不變)。
    /// 兩邊都有有效訂閱丟 `.backend(409, subscription_conflict)`,什麼都沒動。
    public func merge(_ credential: SignInCredential) async throws -> MergeResult {
        let response = try await authorized(
            BackendRequest(method: "POST", path: "/v1/members/me/identities/merge", body: try Wire.encode(credential)))
        let merged = try Wire.decode(Wire.Merge.self, from: response)
        guard let expiresAt = Wire.date(merged.accessTokenExpiresAt) else { throw BackendError.invalidResponse }
        do {
            try tokenStore.setAccessToken(StoredAccessToken(token: merged.accessToken, expiresAt: expiresAt))
        } catch {
            diagnostics(.tokenStorageFailed)
            throw error
        }
        accessToken = (merged.accessToken, expiresAt)
        remember(merged.member)
        return MergeResult(member: try merged.member.domain(), mergedMemberID: merged.mergedMemberId)
    }

    /// 解除連結(後台要求至少保留一種)。
    public func unlink(_ method: SignInMethod) async throws -> Member {
        let response = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me/identities/\(method.rawValue)"))
        let body = try Wire.decode(Wire.MemberEnvelope.self, from: response).member
        remember(body)
        return try body.domain()
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

    /// 把屬於另一個會員的 App Store 訂閱轉給目前會員(呼叫端先要求裝置擁有者驗證)。
    /// 目前會員已有有效訂閱丟 `.backend(409, subscription_already_active)`;回傳目前會員的新訂閱。
    public func transferAppStoreSubscription(_ signedTransaction: String) async throws -> MemberSubscription? {
        let body = try JSONEncoder().encode(["signedTransaction": signedTransaction])
        let response = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/subscription/transfer", body: body))
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
    /// 帶上這支裝置(`device`),同一支裝置的配對在「通知裝置」歸成一台(#266)。
    /// `kinds` 是要收的推播種類;`nil` 時不帶，後台保留既有偏好(新配對只收「需要你」)。
    /// 需要有效訂閱(否則 403 `subscription_required`)。
    public func registerPushPairing(
        keyHash: String, deviceToken: String, environment: PushEnvironment, device: PushDeviceIdentity,
        kinds: Set<PushKind>? = nil
    ) async throws {
        let body = try JSONEncoder().encode(Wire.PushPairingRegistration(
            keyHash: keyHash, platform: "apns", deviceToken: deviceToken, environment: environment.rawValue,
            deviceId: device.id.backendValue, deviceName: device.name, model: device.model.rawValue,
            kinds: kinds.map(PushKind.wireValues)))
        _ = try await authorized(BackendRequest(method: "POST", path: "/v1/members/me/push-pairings", body: body))
    }

    /// 撤銷推播配對(只撤銷自己的;不存在也算成功)。
    public func revokePushPairing(keyHash: String) async throws {
        _ = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me/push-pairings/\(keyHash)"))
    }

    // MARK: - 通知裝置(#266)

    /// 會收到通知的裝置(至少開了一台主機),最新的在前;`currentDeviceID` 的那支標成 `isCurrent`。需要有效訂閱。
    public func pushDevices(currentDeviceID: String) async throws -> [PushDevice] {
        let response = try await authorized(BackendRequest(
            method: "GET", path: "/v1/members/me/push-devices", query: Wire.currentDevice(currentDeviceID)))
        return try Wire.decode(Wire.PushDevices.self, from: response).devices.map { try $0.domain() }
    }

    /// 裝置改名(需要有效訂閱)。不是自己的裝置或已沒有配對丟 404 `device_not_found`。
    public func renamePushDevice(_ deviceID: String, to name: String, currentDeviceID: String) async throws -> PushDevice {
        let response = try await authorized(BackendRequest(
            method: "PATCH", path: "/v1/members/me/push-devices/\(deviceID)", query: Wire.currentDevice(currentDeviceID),
            body: try JSONEncoder().encode(["name": name])))
        return try Wire.decode(Wire.PushDeviceEnvelope.self, from: response).device.domain()
    }

    /// 遠端關閉裝置：撤銷它在所有主機的配對(不需要訂閱，到期也能關掉遺失的手機)。沒有配對丟 404 `device_not_found`。
    public func revokePushDevice(_ deviceID: String) async throws {
        _ = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me/push-devices/\(deviceID)"))
    }

    // MARK: - 登入中的裝置(#409)

    /// 自己未撤銷、未過期的工作階段(每支裝置一個)。
    public func signInDevices() async throws -> [SignInDevice] {
        let response = try await authorized(BackendRequest(method: "GET", path: "/v1/members/me/sessions"))
        return try Wire.decode(Wire.Sessions.self, from: response).sessions.map { try $0.domain() }
    }

    /// 撤銷自己另一支裝置的工作階段(呼叫端先要求裝置擁有者驗證)。撤銷目前這個丟 409 `cannot_revoke_current_session`;已撤銷的再撤銷也成功。
    public func revokeSignInDevice(_ id: String) async throws {
        _ = try await authorized(BackendRequest(method: "DELETE", path: "/v1/members/me/sessions/\(id)"))
    }

    // MARK: - 權杖

    private func authorized(_ request: BackendRequest) async throws -> BackendResponse {
        var request = request
        request.accessToken = try await validAccessToken()
        do {
            return try await send(request)
        } catch let BackendError.backend(status, _, _) where status == 401 {
            // 被拒的存取權杖記憶體與本機都不再用(否則下次又讀回來);換新失敗時更新權杖仍留著。
            accessToken = nil
            try? tokenStore.setAccessToken(nil)
            request.accessToken = try await validAccessToken()
            return try await send(request)
        }
    }

    private func validAccessToken() async throws -> String {
        if accessToken == nil, let stored = try? tokenStore.accessToken() {
            accessToken = (stored.token, stored.expiresAt)
        }
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
            remember(session.member)
            diagnostics(.refreshed)
            return try session.member.domain()
        } catch let BackendError.backend(status, code, _) where status == 401 && code == BackendErrorCode.invalidRefreshToken {
            // 後台明確拒絕:工作階段已撤銷、過期,或寬限外重用舊權杖。這是唯一會登出的情況。
            diagnostics(.refreshRejected(code: code))
            try clear()
            throw BackendError.signedOut
        } catch let error as BackendError {
            switch error {
            case .unreachable: diagnostics(.refreshUnavailable(reason: "unreachable"))
            case .backend(let status, let code, _): diagnostics(.refreshUnavailable(reason: "\(status) \(code)"))
            case .invalidResponse: diagnostics(.refreshUnavailable(reason: "invalid_response"))
            case .signedOut, .subscriptionInUse, .mergeRequired: break
            }
            throw error
        }
    }

    /// 存下新權杖:先寫更新權杖(失去它就登出,最重要),再寫存取權杖,最後才換記憶體。
    /// 任何一步寫入失敗都丟出、不動舊的;60 秒內用舊更新權杖重換會拿回同一組新權杖。
    private func adopt(_ session: Wire.Session) throws {
        guard let expiresAt = Wire.date(session.accessTokenExpiresAt) else { throw BackendError.invalidResponse }
        do {
            try tokenStore.setRefreshToken(session.refreshToken)
            try tokenStore.setAccessToken(StoredAccessToken(token: session.accessToken, expiresAt: expiresAt))
        } catch {
            diagnostics(.tokenStorageFailed)
            throw error
        }
        accessToken = (session.accessToken, expiresAt)
    }

    /// 留下會員快照(盡力而為):連不上後台時仍知道是誰登入。
    private func remember(_ member: Wire.MemberBody) {
        guard let data = try? JSONEncoder().encode(member) else { return }
        try? tokenStore.setMemberSnapshot(data)
    }

    private func clear() throws {
        accessToken = nil
        try tokenStore.setRefreshToken(nil)
        try tokenStore.setAccessToken(nil)
        try tokenStore.setMemberSnapshot(nil)
        diagnostics(.cleared)
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
            if envelope.error.code == BackendErrorCode.subscriptionInUse {
                throw BackendError.subscriptionInUse(
                    ownerEmail: envelope.error.details?.ownerEmail, canTransfer: envelope.error.details?.canTransfer ?? true)
            }
            if envelope.error.code == BackendErrorCode.mergeRequired, let details = envelope.error.mergeDetails {
                throw BackendError.mergeRequired(details.domain())
            }
            throw BackendError.backend(status: response.status, code: envelope.error.code, message: envelope.error.message)
        }
        return response
    }
}

/// 後台 JSON 的形狀(raychiutw/purrdr.server 的 README.md)。
private enum Wire {
    struct Credential: Encodable {
        var provider: String
        var idToken: String
        var nonce: String
        var authorizationCode: String?
        /// 登入時才帶(連結另一種登入方式不帶)。
        var deviceId: String?
        var platform: String?
        /// 只在登入頁(不新建會員)帶 `false`。
        var createMember: Bool?
    }

    struct Session: Decodable {
        var accessToken: String
        var accessTokenExpiresAt: String
        var refreshToken: String
        var memberCreated: Bool?
        var autoLinked: Bool?
        var member: MemberBody
    }

    struct MemberEnvelope: Decodable {
        var member: MemberBody
    }

    struct Link: Decodable {
        var member: MemberBody
    }

    struct Merge: Decodable {
        var member: MemberBody
        var mergedMemberId: String
        var accessToken: String
        var accessTokenExpiresAt: String
    }

    /// `merge_required` 的 `error.details`(合併確認摘要)。
    struct MergeDetails: Decodable {
        var canMerge: Bool
        var current: Side
        var other: Side

        struct Side: Decodable {
            var identities: [Identity]
            var hasActiveSubscription: Bool
            var hostCount: Int

            struct Identity: Decodable {
                var provider: String
                var email: String?
            }
        }

        func domain() -> MemberMergeSummary {
            func side(_ side: Side) -> MemberMergeSummary.Side {
                .init(
                    // 不認得的登入方式(之後新增的)略過。
                    identities: side.identities.compactMap { identity in
                        SignInMethod(rawValue: identity.provider).map { .init(method: $0, email: identity.email) }
                    },
                    hasActiveSubscription: side.hasActiveSubscription, hostCount: side.hostCount)
            }
            return MemberMergeSummary(canMerge: canMerge, current: side(current), other: side(other))
        }
    }

    struct MemberBody: Codable {
        var id: String
        var identities: [Identity]

        struct Identity: Codable {
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
        /// 升級合併後沒保留的有效訂閱(後台 PR #34);帳號頁提示使用者到商店取消。
        var pendingReview: Bool?

        func domain() throws -> MemberSubscription {
            // 後台對外把 billing_retry 當作 expired(沒有權限);萬一直接收到,同樣視為已到期。
            guard let status = MemberSubscription.Status(rawValue: status == "billing_retry" ? "expired" : status),
                  let store = MemberSubscription.Store(rawValue: store),
                  let expiresAt = Wire.date(expiresAt)
            else { throw BackendError.invalidResponse }
            return MemberSubscription(
                status: status, store: store, productID: productId, expiresAt: expiresAt,
                gracePeriodExpiresAt: gracePeriodExpiresAt.flatMap(Wire.date), willAutoRenew: willAutoRenew,
                pendingReview: pendingReview ?? false
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
        /// 主機圖示(#243)。舊版後台與舊版 app 上傳的主機沒有。
        var icon: String?
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
            icon = host.icon
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
            try container.encodeIfPresent(icon, forKey: .icon)
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
            // HTTPS 主機的主機服務位址以 address＋port 為唯一來源(#250)。
            let hostService = method.usesHostService ? HostServiceAddress(host: address, port: port) : nil
            if method.usesHostService, hostService == nil { throw BackendError.invalidResponse }
            guard let id = UUID(uuidString: id), let modifiedAt = Wire.date(modifiedAt) else { throw BackendError.invalidResponse }
            return SyncedHost(
                id: id, name: name, endpoint: SSHEndpoint(host: address, port: port, username: username), connectionMethod: method,
                hostKeyPin: hostKeyFingerprint.flatMap(HostKeyFingerprint.init(stored:)),
                hostService: hostService, icon: icon, modifiedAt: modifiedAt)
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

    static func currentDevice(_ deviceID: String) -> [URLQueryItem] {
        [URLQueryItem(name: "currentDeviceId", value: deviceID)]
    }

    /// 註冊推播配對的 body;`kinds` 是 `nil` 時整個欄位不送。
    struct PushPairingRegistration: Encodable {
        var keyHash: String
        var platform: String
        var deviceToken: String
        var environment: String
        var deviceId: String
        var deviceName: String
        var model: String
        var kinds: [String]?
    }

    struct PushDevices: Decodable {
        var devices: [PushDeviceBody]
    }

    struct PushDeviceEnvelope: Decodable {
        var device: PushDeviceBody
    }

    struct PushDeviceBody: Decodable {
        var deviceId: String
        var name: String?
        var model: String?
        var hostCount: Int
        /// epoch 毫秒。
        var lastRegisteredAt: Double
        var current: Bool

        func domain() throws -> PushDevice {
            PushDevice(
                id: deviceId, name: name, model: model.flatMap(PushDeviceModel.init(rawValue:)), hostCount: hostCount,
                lastRegisteredAt: Date(timeIntervalSince1970: lastRegisteredAt / 1000), isCurrent: current)
        }
    }

    struct Sessions: Decodable {
        var sessions: [SessionBody]
    }

    struct SessionBody: Decodable {
        var id: String
        var deviceName: String?
        var deviceModel: String?
        var lastActiveAt: String
        var current: Bool

        func domain() throws -> SignInDevice {
            guard let lastActive = Wire.date(lastActiveAt) else { throw BackendError.invalidResponse }
            return SignInDevice(id: id, name: deviceName, model: deviceModel, lastActiveAt: lastActive, isCurrent: current)
        }
    }

    struct ErrorEnvelope: Decodable {
        var error: Body

        struct Body: Decodable {
            var code: String
            var message: String
            /// `subscription_in_use` 的 `details`;其他錯誤的 `details`(例如合併摘要)形狀不同,讀不懂就略過。
            var details: InUseDetails?
            /// `merge_required` 的 `details`。
            var mergeDetails: MergeDetails?

            enum CodingKeys: String, CodingKey { case code, message, details }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = try container.decode(String.self, forKey: .code)
                message = try container.decode(String.self, forKey: .message)
                details = try? container.decodeIfPresent(InUseDetails.self, forKey: .details)
                mergeDetails = try? container.decodeIfPresent(MergeDetails.self, forKey: .details)
            }
        }

        struct InUseDetails: Decodable {
            var ownerEmail: String?
            var canTransfer: Bool?
        }
    }

    /// `deviceID` 非 `nil` 表示是「登入」:帶上這支裝置的 id 與平台。連結另一種登入方式(`nil`)只送憑證。
    static func encode(_ credential: SignInCredential, deviceID: String? = nil, isSignIn: Bool = false, createMember: Bool? = nil) throws -> Data {
        try JSONEncoder().encode(Credential(
            provider: credential.method.rawValue,
            idToken: credential.idToken,
            nonce: credential.nonce,
            authorizationCode: credential.authorizationCode,
            deviceId: deviceID,
            platform: isSignIn ? "ios" : nil,
            createMember: createMember
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

/// 會員流程的診斷事件(#406):只有結果碼,不含 email、權杖或會員 ID。
public enum MemberDiagnosticEvent: Equatable, Sendable {
    /// 登入成功。
    case signedIn
    /// 換權杖成功。
    case refreshed
    /// 後台明確拒絕更新權杖(登入失效、被撤銷或重用舊權杖)。
    case refreshRejected(code: String)
    /// 換權杖時連不上或後台暫時出錯(保留登入)。
    case refreshUnavailable(reason: String)
    /// 權杖寫不進本機存放。
    case tokenStorageFailed
    /// 登出或刪除會員後清掉本機登入資料。
    case cleared
}

public typealias MemberDiagnostics = @Sendable (MemberDiagnosticEvent) -> Void
