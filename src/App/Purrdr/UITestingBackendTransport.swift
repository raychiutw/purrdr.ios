import Foundation
import PurrdrCore
import Synchronization

/// UI 測試的假後台(#246):`-uiTestingMember` 是已登入、未開通;`-uiTestingPlusMember` 另有有效的 Purrdr Plus。
///
/// 不連網路。只回帳號頁流程用到的路徑：換權杖、讀會員與訂閱、主機同步(回傳送來的主機)、推播配對、通知裝置;其餘回 404。
/// 通知裝置(#266):一開始有另一支「Studio iPad」與一支舊版 app 註冊的未命名裝置;這支裝置開了主機才列出。
final class UITestingBackendTransport: BackendTransport {
    /// 啟動時就有的更新權杖(MemberSession 以它換成上面的會員)。
    static let refreshToken = "ui-testing-refresh"
    /// 舊版 app 在後台遷移前發的更新權杖(#414):遷移後一律被拒絕(401 `invalid_refresh_token`),使用者要重新登入一次。
    static let staleRefreshToken = "ui-testing-stale-refresh"
    /// 這支裝置在 UI 測試的 id(composition root 帶給推播)。
    static let thisDeviceID = "5eed0000-0000-4000-8000-0000000000d1"
    static let studioIPadID = "5eed0000-0000-4000-8000-0000000000d2"
    static let legacyDeviceID = "legacy-5eed00000000000000000000000000d3"

    /// 假後台的訂閱情境(#409,帳號頁 Plus 卡各狀態)。
    enum Scenario: Equatable {
        /// 沒有訂閱。
        case none
        /// App Store 訂閱生效中。
        case active
        /// Google Play 訂閱(iOS 只顯示來源)。
        case googlePlay
        /// 帳單寬限期。
        case grace
        /// 已到期。
        case expired
        /// 這個 Apple 帳號的訂閱屬於另一個會員:提交交易回 `subscription_in_use`,轉移後變成生效中。
        case ownedByAnotherMember
        /// 生效中,但升級合併後有另一個待處理的訂閱。
        case pendingReview
    }

    let scenario: Scenario
    var isPlusActive: Bool { Self.entitles(scenario) }
    /// 轉移成功之後(`.ownedByAnotherMember`)。
    private let transferred = Mutex(false)
    /// 一開始就有更新權杖(已登入)。`false` 是 `-uiTestingSignUp`:沒登入,Apple／Google 按鈕直接以固定憑證登入這個假後台(#408)。
    let startsSignedIn: Bool
    /// `-uiTestingLinkMerge`(#410):連結 Google 時發現它已屬於另一個會員(回合併確認摘要);沒帶就直接連結成功。
    let linkFindsAnotherMember: Bool
    /// 兩邊都有有效訂閱(`-uiTestingLinkMergeBlocked`):摘要的 `canMerge` 是 `false`。
    let mergeBlocked: Bool
    /// `-uiTestingNoMember`(#453):沒有會員的帳號。登入頁(`createMember: false`)回 404 `member_not_found`,加入頁照舊新建。
    let hasNoMember: Bool
    /// `-uiTestingUpgradedMember`(#414):啟動時帶著遷移前的更新權杖(後台拒絕),重新登入後的訂閱是升級合併後有待處理訂閱的情境。
    let startsWithStaleToken: Bool
    /// 這個會員已綁定 Google(連結或合併成功之後)。
    private let googleLinked = Mutex(false)

    private struct Device {
        var id: String
        var name: String?
        var model: String?
        /// 這支裝置送來的配對(雜湊);種子裝置只記數量。
        var keyHashes: Set<String>
        var hostCount: Int
        var lastRegisteredAt: Int
    }

    private let devices = Mutex<[Device]>([
        Device(id: studioIPadID, name: "Studio iPad", model: "iPad", keyHashes: [], hostCount: 2, lastRegisteredAt: 1_794_729_600_000),
        Device(id: legacyDeviceID, name: nil, model: nil, keyHashes: [], hostCount: 1, lastRegisteredAt: 1_794_643_200_000),
    ])

    convenience init(isPlusActive: Bool, startsSignedIn: Bool = true) {
        self.init(scenario: isPlusActive ? .active : .none, startsSignedIn: startsSignedIn)
    }

    init(scenario: Scenario, startsSignedIn: Bool = true, linkFindsAnotherMember: Bool = false, mergeBlocked: Bool = false, hasNoMember: Bool = false, startsWithStaleToken: Bool = false) {
        self.hasNoMember = hasNoMember
        self.startsWithStaleToken = startsWithStaleToken
        self.scenario = scenario
        self.startsSignedIn = startsSignedIn
        self.linkFindsAnotherMember = linkFindsAnotherMember
        self.mergeBlocked = mergeBlocked
    }

    private static func entitles(_ scenario: Scenario) -> Bool {
        switch scenario {
        case .active, .googlePlay, .grace, .pendingReview: true
        case .none, .expired, .ownedByAnotherMember: false
        }
    }

    func send(_ request: BackendRequest) async throws -> BackendResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/sessions"):
            // 登入或註冊:ID token 含 `new` 的是新會員(`memberCreated: true`),其餘是既有會員。
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let idToken = body?["idToken"] as? String
            if hasNoMember, body?["createMember"] as? Bool == false { return Self.error(404, "member_not_found") }
            let created = idToken?.contains("new") == true
            return Self.json(#"{"accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"\#(Self.refreshToken)","memberCreated":\#(created),"autoLinked":false,"member":\#(memberBody)}"#)
        case ("POST", "/v1/sessions/refresh"):
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if body?["refreshToken"] as? String == Self.staleRefreshToken { return Self.error(401, "invalid_refresh_token") }
            return Self.json(#"{"accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"\#(Self.refreshToken)","member":\#(memberBody)}"#)
        case ("GET", "/v1/members/me"):
            return Self.json(#"{"member":\#(memberBody)}"#)
        case ("GET", "/v1/members/me/subscription"):
            return Self.json(subscriptionJSON.map { #"{"subscription":\#($0)}"# } ?? #"{"subscription":null}"#)
        case ("POST", "/v1/members/me/subscription/app-store"):
            // 這個 Apple 帳號的訂閱屬於另一個會員(轉移前)。
            if scenario == .ownedByAnotherMember, !transferred.withLock({ $0 }) {
                return BackendResponse(status: 409, body: Data(Self.inUse.utf8))
            }
            return Self.json(#"{"subscription":\#(Self.subscription())}"#)
        case ("POST", "/v1/members/me/subscription/transfer"):
            transferred.withLock { $0 = true }
            return Self.json(#"{"subscription":\#(Self.subscription()),"appAccountTokenUpdated":true}"#)
        case ("POST", "/v1/members/me/identities"):
            if googleLinked.withLock({ $0 }) { return Self.error(409, "provider_already_linked") }
            if linkFindsAnotherMember { return BackendResponse(status: 409, body: Data(mergeRequired.utf8)) }
            googleLinked.withLock { $0 = true }
            return Self.json(#"{"member":\#(memberBody),"mergedMemberId":null}"#)
        case ("POST", "/v1/members/me/identities/merge"):
            if mergeBlocked { return Self.error(409, "subscription_conflict") }
            googleLinked.withLock { $0 = true }
            return Self.json(#"{"member":\#(memberBody),"mergedMemberId":"ui-testing-other-member","accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z"}"#)
        case ("DELETE", "/v1/members/me/identities/google"):
            googleLinked.withLock { $0 = false }
            return Self.json(#"{"member":\#(memberBody)}"#)
        case ("GET", "/v1/members/me/sessions"):
            return Self.json(Self.sessionsJSON)
        case ("DELETE", let path) where path.hasPrefix("/v1/members/me/sessions/"):
            return BackendResponse(status: 204, body: Data())
        case ("POST", "/v1/members/me/hosts/sync"):
            return Self.syncResponse(echoing: request.body)
        case ("POST", "/v1/members/me/push-pairings"):
            registerPairing(request.body)
            return BackendResponse(status: 204, body: Data())
        case ("POST", "/v1/sessions/revoke"):
            return BackendResponse(status: 204, body: Data())
        case ("DELETE", let path) where path.hasPrefix(Self.pairingsPath):
            revokePairing(String(path.dropFirst(Self.pairingsPath.count)))
            return BackendResponse(status: 204, body: Data())
        case ("GET", "/v1/members/me/push-usage"):
            // 今日用量(#677):固定 23／100,下次歸零是下一個 UTC 0:00。
            let seconds = (Date().timeIntervalSince1970 / 86_400).rounded(.down) * 86_400 + 86_400
            let reset = Date(timeIntervalSince1970: seconds).formatted(.iso8601)
            return Self.json(#"{"usage":{"limit":100,"sent":23,"resetsAt":"\#(reset)"}}"#)
        case ("GET", "/v1/members/me/push-devices"):
            // 清單與關閉不需要 Plus(訂閱到期也能關閉遺失的裝置);改名才要。
            let current = Self.currentDeviceID(request)
            let listed = devices.withLock { $0 }.filter { $0.hostCount > 0 }.map { Self.json($0, current: current) }
            return Self.json(#"{"devices":[\#(listed.joined(separator: ","))]}"#)
        case ("PATCH", let path) where path.hasPrefix(Self.devicesPath):
            guard isPlusActive else { return Self.subscriptionRequired }
            let id = String(path.dropFirst(Self.devicesPath.count))
            let name = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["name"]
            let renamed = devices.withLock { devices -> Device? in
                guard let index = devices.firstIndex(where: { $0.id == id && $0.hostCount > 0 }) else { return nil }
                devices[index].name = name
                return devices[index]
            }
            guard let renamed else { return Self.deviceNotFound }
            return Self.json(#"{"device":\#(Self.json(renamed, current: Self.currentDeviceID(request)))}"#)
        case ("DELETE", let path) where path.hasPrefix(Self.devicesPath):
            let id = String(path.dropFirst(Self.devicesPath.count))
            let removed = devices.withLock { devices -> Bool in
                guard let index = devices.firstIndex(where: { $0.id == id && $0.hostCount > 0 }) else { return false }
                devices[index].keyHashes = []
                devices[index].hostCount = 0
                return true
            }
            return removed ? BackendResponse(status: 204, body: Data()) : Self.deviceNotFound
        default:
            return BackendResponse(status: 404, body: Data(#"{"error":{"code":"not_found","message":"UI testing backend"}}"#.utf8))
        }
    }

    private static let pairingsPath = "/v1/members/me/push-pairings/"
    private static let devicesPath = "/v1/members/me/push-devices/"

    private static let subscriptionRequired =
        BackendResponse(status: 403, body: Data(#"{"error":{"code":"subscription_required","message":"UI testing backend"}}"#.utf8))

    private static let deviceNotFound =
        BackendResponse(status: 404, body: Data(#"{"error":{"code":"device_not_found","message":"UI testing backend"}}"#.utf8))

    private static func currentDeviceID(_ request: BackendRequest) -> String? {
        request.query.first { $0.name == "currentDeviceId" }?.value
    }

    /// 註冊配對：依 `deviceId` 歸到同一支裝置;已有名稱就不覆蓋(與後台相同)。
    private func registerPairing(_ body: Data?) {
        // `kinds` 是陣列(#292),只取字串欄位。
        guard let json = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
        let fields = json.compactMapValues { $0 as? String }
        guard let keyHash = fields["keyHash"], let id = fields["deviceId"] else { return }
        devices.withLock { devices in
            if let index = devices.firstIndex(where: { $0.id == id }) {
                devices[index].keyHashes.insert(keyHash)
                devices[index].hostCount = devices[index].keyHashes.count
                devices[index].name = devices[index].name ?? fields["deviceName"]
            } else {
                let device = Device(
                    id: id, name: fields["deviceName"], model: fields["model"], keyHashes: [keyHash], hostCount: 1,
                    lastRegisteredAt: 1_794_816_000_000)
                devices.insert(device, at: 0)
            }
        }
    }

    private func revokePairing(_ keyHash: String) {
        devices.withLock { devices in
            for index in devices.indices where devices[index].keyHashes.contains(keyHash) {
                devices[index].keyHashes.remove(keyHash)
                devices[index].hostCount = devices[index].keyHashes.count
            }
        }
    }

    private static func json(_ device: Device, current: String?) -> String {
        let fields: [String: Any] = [
            "deviceId": device.id, "name": device.name ?? NSNull(), "model": device.model ?? NSNull(),
            "hostCount": device.hostCount, "lastRegisteredAt": device.lastRegisteredAt, "current": device.id == current,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static let memberJSON =
        #"{"id":"ui-testing-member","identities":[{"provider":"apple","email":"ray@example.com","linkedAt":"2026-01-01T00:00:00.000Z"}]}"#

    /// 目前的會員(連結或合併 Google 之後多一種登入方式)。
    private var memberBody: String {
        guard googleLinked.withLock({ $0 }) else { return Self.memberJSON }
        return #"{"id":"ui-testing-member","identities":[{"provider":"apple","email":"ray@example.com","linkedAt":"2026-01-01T00:00:00.000Z"},{"provider":"google","email":"ray@gmail.com","linkedAt":"2026-01-02T00:00:00.000Z"}]}"#
    }

    /// 連結時發現已屬另一個會員:合併確認摘要(`error.details`)。
    private var mergeRequired: String {
        #"{"error":{"code":"merge_required","message":"UI testing backend","details":{"canMerge":\#(!mergeBlocked),"current":{"identities":[{"provider":"apple","email":"r***@example.com"}],"hasActiveSubscription":\#(mergeBlocked || isPlusActive),"hostCount":2},"other":{"identities":[{"provider":"google","email":"r***@gmail.com"}],"hasActiveSubscription":\#(mergeBlocked),"hostCount":1}}}}"#
    }

    private static func error(_ status: Int, _ code: String) -> BackendResponse {
        BackendResponse(status: status, body: Data(#"{"error":{"code":"\#(code)","message":"UI testing backend"}}"#.utf8))
    }

    /// 目前情境的訂閱 JSON;沒有訂閱(或轉移前屬於別人)是 `nil`。
    private var subscriptionJSON: String? {
        switch scenario {
        case .none: return nil
        case .active: return Self.subscription()
        case .googlePlay: return Self.subscription(store: "google_play")
        case .grace: return Self.subscription(status: "in_grace_period", graceUntil: "2099-01-05T00:00:00.000Z")
        case .expired: return Self.subscription(status: "expired", expiresAt: "2026-11-20T00:00:00.000Z")
        case .ownedByAnotherMember: return transferred.withLock { $0 } ? Self.subscription() : nil
        case .pendingReview: return Self.subscription(pendingReview: true)
        }
    }

    private static func subscription(
        status: String = "active", store: String = "app_store", expiresAt: String = "2099-01-01T00:00:00.000Z", graceUntil: String? = nil,
        pendingReview: Bool = false
    ) -> String {
        let grace = graceUntil.map { #""\#($0)""# } ?? "null"
        return #"{"status":"\#(status)","store":"\#(store)","productId":"com.raychiu.purrdr.plus.yearly","expiresAt":"\#(expiresAt)","gracePeriodExpiresAt":\#(grace),"willAutoRenew":true,"pendingReview":\#(pendingReview)}"#
    }

    private static let inUse =
        #"{"error":{"code":"subscription_in_use","message":"UI testing backend","details":{"ownerEmail":"r***@icloud.com","canTransfer":true}}}"#

    /// 登入中的裝置:這支與另一支 iPad。
    private static let sessionsJSON = #"""
        {"sessions":[
          {"id":"ui-session-this","deviceId":"5eed0000-0000-4000-8000-0000000000d1","deviceName":"iPhone","deviceModel":"iPhone",
           "createdAt":"2026-11-01T00:00:00.000Z","lastActiveAt":"2026-11-21T08:00:00.000Z","expiresAt":"2027-02-01T00:00:00.000Z","current":true},
          {"id":"ui-session-ipad","deviceId":"5eed0000-0000-4000-8000-0000000000d2","deviceName":"Studio iPad","deviceModel":"iPad",
           "createdAt":"2026-10-01T00:00:00.000Z","lastActiveAt":"2026-11-20T08:00:00.000Z","expiresAt":"2027-01-01T00:00:00.000Z","current":false}
        ]}
        """#

    /// 後台只有這支裝置送來的主機：上傳的原樣回傳，刪除的列進 `deletedHostIds`。
    private static func syncResponse(echoing body: Data?) -> BackendResponse {
        let request = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let changes = request?["changes"] as? [[String: Any]] ?? []
        let hosts = changes.filter { $0["deleted"] == nil }
        let deletedIDs = changes.filter { $0["deleted"] != nil }.compactMap { $0["id"] as? String }
        let data = (try? JSONSerialization.data(withJSONObject: ["hosts": hosts, "deletedHostIds": deletedIDs])) ?? Data()
        return BackendResponse(status: 200, body: data)
    }

    private static func json(_ text: String) -> BackendResponse {
        BackendResponse(status: 200, body: Data(text.utf8))
    }
}

/// UI 測試的「暫時連不上」(`-uiTestingMemberOffline`):後台一律連不上。
struct UITestingOfflineBackend: BackendTransport {
    func send(_ request: BackendRequest) async throws -> BackendResponse {
        throw BackendError.unreachable
    }
}

/// UI 測試的「後台一直沒回應」(`-uiTestingMemberLoading`):帳號頁停在第一次載入的骨架(#496)。
struct UITestingHangingBackend: BackendTransport {
    func send(_ request: BackendRequest) async throws -> BackendResponse {
        try await Task.sleep(for: .seconds(3600))
        throw BackendError.unreachable
    }
}
