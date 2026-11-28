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
    }

    let scenario: Scenario
    var isPlusActive: Bool { Self.entitles(scenario) }
    /// 一開始就有更新權杖(已登入)。`false`(`-uiTestingNoMember`):沒登入,Apple／Google 按鈕直接以固定憑證登入這個假後台(#408)。
    let startsSignedIn: Bool
    /// `-uiTestingLinkMerge`(#410):連結 Google 時發現它已屬於另一個會員(回合併確認摘要);沒帶就直接連結成功。
    let linkFindsAnotherMember: Bool
    /// `-uiTestingNoMember`(#453):沒有會員的帳號。登入頁(`createMember: false`)回 404 `member_not_found`,加入頁照舊新建。
    let hasNoMember: Bool
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
        /// 種子裝置開了通知的主機(名稱、圖示代號);真的註冊來的裝置改由 `pairingProfiles` 組。
        var seedHosts: [(name: String, symbol: String)] = []
    }

    private let devices = Mutex<[Device]>([
        Device(id: studioIPadID, name: "Studio iPad", model: "iPad", keyHashes: [], hostCount: 2, lastRegisteredAt: 1_794_729_600_000,
               seedHosts: [("Studio Mac", "desktopcomputer"), ("Build Box", "server.rack")]),
        Device(id: legacyDeviceID, name: nil, model: nil, keyHashes: [], hostCount: 1, lastRegisteredAt: 1_794_643_200_000,
               seedHosts: [("Old Laptop", "laptopcomputer")]),
    ])

    convenience init(isPlusActive: Bool, startsSignedIn: Bool = true) {
        self.init(scenario: isPlusActive ? .active : .none, startsSignedIn: startsSignedIn)
    }

    init(scenario: Scenario, startsSignedIn: Bool = true, linkFindsAnotherMember: Bool = false, hasNoMember: Bool = false) {
        self.hasNoMember = hasNoMember
        self.scenario = scenario
        self.startsSignedIn = startsSignedIn
        self.linkFindsAnotherMember = linkFindsAnotherMember
    }

    private static func entitles(_ scenario: Scenario) -> Bool {
        switch scenario {
        case .active: true
        case .none: false
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
            return Self.json(#"{"accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"\#(Self.refreshToken)","member":\#(memberBody)}"#)
        case ("GET", "/v1/members/me"):
            return Self.json(#"{"member":\#(memberBody)}"#)
        case ("GET", "/v1/members/me/subscription"):
            return Self.json(subscriptionJSON.map { #"{"subscription":\#($0)}"# } ?? #"{"subscription":null}"#)
        case ("POST", "/v1/members/me/subscription/app-store"):
            return Self.json(#"{"subscription":\#(Self.subscription())}"#)
        case ("POST", "/v1/members/me/identities"):
            if googleLinked.withLock({ $0 }) { return Self.error(409, "provider_already_linked") }
            if linkFindsAnotherMember { return BackendResponse(status: 409, body: Data(mergeRequired.utf8)) }
            googleLinked.withLock { $0 = true }
            return Self.json(#"{"member":\#(memberBody),"mergedMemberId":null}"#)
        case ("POST", "/v1/members/me/identities/merge"):
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
        case ("GET", "/v1/push-kinds"):
            // 種類清單(ADR-0016):與後台同形狀;順序、預設、連線方式與最低版本由這份決定。
            return Self.json(Self.pushKindsJSON)
        case ("GET", "/v1/members/me/push-pairings"):
            let deviceID = request.query.first { $0.name == "deviceId" }?.value
            return Self.json(pairingsJSON(deviceID: deviceID))
        case ("PATCH", let path) where path.hasPrefix(Self.pairingsPath):
            return patchPairing(String(path.dropFirst(Self.pairingsPath.count)), body: request.body)
        case ("POST", "/v1/sessions/revoke"):
            return BackendResponse(status: 204, body: Data())
        case ("DELETE", let path) where path.hasPrefix(Self.pairingsPath):
            revokePairing(String(path.dropFirst(Self.pairingsPath.count)))
            return BackendResponse(status: 204, body: Data())
        case ("GET", "/v1/members/me/push-devices"):
            // 清單與關閉不需要 Plus(訂閱到期也能關閉遺失的裝置);改名才要。
            let current = Self.currentDeviceID(request)
            let listed = devices.withLock { $0 }.filter { $0.hostCount > 0 }.map { json($0, current: current) }
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
            return Self.json(#"{"device":\#(json(renamed, current: Self.currentDeviceID(request)))}"#)
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

    /// 種類清單:`transports` 只有 https 的 `queue_paused` 在 SSH 主機(UI 測試的 Demo 主機)是停用並說明。
    static let pushKindsJSON = #"""
        {"kinds":[
          {"code":"blocked","name":{"en":"Needs You","zh-Hant":"需要你"},"description":{"en":"An agent is waiting for your answer or approval.","zh-Hant":"Agent 在等你回答或核准。"},"defaultOn":true,"transports":["ssh","https"],"minServiceVersion":null,"minPluginVersion":null,"order":10},
          {"code":"done","name":{"en":"Finished","zh-Hant":"完成"},"description":{"en":"An agent finished its work.","zh-Hant":"Agent 做完了。"},"defaultOn":true,"transports":["ssh","https"],"minServiceVersion":null,"minPluginVersion":null,"order":20},
          {"code":"queue_paused","name":{"en":"Queued send paused","zh-Hant":"預約送出被暫停"},"description":{"en":"A queued message was not sent.","zh-Hant":"排好的訊息沒有送出。"},"defaultOn":true,"transports":["https"],"minServiceVersion":"0.16.0","minPluginVersion":null,"order":30},
          {"code":"daily_limit_reached","name":{"en":"Daily limit reached","zh-Hant":"每日上限已達"},"description":{"en":"Today’s notification limit was reached.","zh-Hant":"今天的通知已達上限。"},"defaultOn":true,"transports":["ssh","https"],"minServiceVersion":null,"minPluginVersion":null,"order":90}
        ]}
        """#
    private static let knownKindCodes: Set<String> = ["blocked", "done", "queue_paused", "daily_limit_reached"]
    private static let defaultPairingKinds = ["blocked", "daily_limit_reached"]
    /// 各配對收的種類(雜湊 → 代號);沒記過的用預設。
    private let pairingKinds = Mutex<[String: [String]]>([:])
    /// 配對的主機名稱與圖示(purrdr.server#45):註冊與 PATCH 帶上來的值,`icon` 是 `{symbol,color}`。
    private let pairingProfiles = Mutex<[String: (name: String?, icon: [String: String]?)]>([:])

    private func profileFields(_ keyHash: String) -> (name: Any, icon: Any) {
        let profile = pairingProfiles.withLock { $0[keyHash] }
        return (profile?.name ?? NSNull(), profile?.icon ?? NSNull())
    }

    /// 註冊或 PATCH 的 body 帶了 `name`／`icon` 就記下(`icon` 是 `null` 代表清掉)。
    private func recordProfile(_ keyHash: String, from json: [String: Any]) {
        pairingProfiles.withLock { profiles in
            var profile = profiles[keyHash] ?? (name: nil, icon: nil)
            if let name = json["name"] as? String { profile.name = name }
            if json["icon"] is NSNull { profile.icon = nil } else if let icon = json["icon"] as? [String: String] { profile.icon = icon }
            profiles[keyHash] = profile
        }
    }

    private func pairingsJSON(deviceID: String?) -> String {
        let hashes = devices.withLock { $0 }.filter { deviceID == nil || $0.id == deviceID }.flatMap(\.keyHashes).sorted()
        let kinds = pairingKinds.withLock { $0 }
        let listed = hashes.map { hash -> [String: Any] in
            ["keyHash": hash, "name": profileFields(hash).name, "icon": profileFields(hash).icon, "kinds": kinds[hash] ?? Self.defaultPairingKinds]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["pairings": listed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func patchPairing(_ keyHash: String, body: Data?) -> BackendResponse {
        guard devices.withLock({ $0 }).contains(where: { $0.keyHashes.contains(keyHash) }) else { return Self.error(404, "pairing_not_found") }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // 只改名稱或圖示的 PATCH 沒有 `kinds`;有就照舊驗證。
        if let json { recordProfile(keyHash, from: json) }
        if json?["kinds"] != nil {
            guard let kinds = json?["kinds"] as? [String], kinds.allSatisfy(Self.knownKindCodes.contains) else { return Self.error(400, "invalid_kind") }
            pairingKinds.withLock { $0[keyHash] = kinds }
        }
        let kinds = pairingKinds.withLock { $0[keyHash] } ?? Self.defaultPairingKinds
        let pairing: [String: Any] = ["keyHash": keyHash, "name": profileFields(keyHash).name, "icon": profileFields(keyHash).icon, "kinds": kinds]
        let data = (try? JSONSerialization.data(withJSONObject: ["pairing": pairing])) ?? Data()
        return Self.json(String(decoding: data, as: UTF8.self))
    }
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
        if let kinds = json["kinds"] as? [String] { pairingKinds.withLock { $0[keyHash] = kinds } }
        recordProfile(keyHash, from: json)
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

    private func json(_ device: Device, current: String?) -> String {
        // 開了通知的主機(名稱與圖示,purrdr.server#45):註冊來的裝置由配對的紀錄組,種子裝置用內建的。
        let hosts: [[String: Any]] = device.keyHashes.isEmpty
            ? device.seedHosts.map { ["keyHash": "seed-\($0.name)", "name": $0.name, "icon": ["symbol": $0.symbol, "color": "#0B7A5C"]] }
            : device.keyHashes.sorted().map { ["keyHash": $0, "name": profileFields($0).name, "icon": profileFields($0).icon] }
        let fields: [String: Any] = [
            "deviceId": device.id, "name": device.name ?? NSNull(), "model": device.model ?? NSNull(),
            "hostCount": device.hostCount, "hosts": hosts, "lastRegisteredAt": device.lastRegisteredAt, "current": device.id == current,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static let memberJSON =
        #"{"id":"ui-testing-member","identities":[{"provider":"apple","email":"ray@example.com","linkedAt":"2026-01-01T00:00:00.000Z"}]}"#

    /// 目前的會員(連結或合併 Google 之後多一種登入方式)。
    private var memberBody: String {
        let body = googleLinked.withLock({ $0 })
            ? #"{"id":"ui-testing-member","identities":[{"provider":"apple","email":"ray@example.com","linkedAt":"2026-01-01T00:00:00.000Z"},{"provider":"google","email":"ray@example.org","linkedAt":"2026-01-02T00:00:00.000Z"}]}"#
            : Self.memberJSON
        return String(body.dropLast()) + #","pushUsage":\#(Self.pushUsageJSON)}"#
    }

    /// 今日用量(#677):固定 23／100,下次歸零是下一個 UTC 0:00。併在會員快照(purrdr.server#37)。
    private static var pushUsageJSON: String {
        let seconds = (Date().timeIntervalSince1970 / 86_400).rounded(.down) * 86_400 + 86_400
        let reset = Date(timeIntervalSince1970: seconds).formatted(.iso8601)
        return #"{"limit":100,"sent":23,"resetsAt":"\#(reset)"}"#
    }

    /// 連結時發現已屬另一個會員:合併確認摘要(`error.details`)。
    private var mergeRequired: String {
        #"{"error":{"code":"merge_required","message":"UI testing backend","details":{"canMerge":true,"current":{"identities":[{"provider":"apple","email":"r***@example.com"}],"hasActiveSubscription":\#(isPlusActive),"hostCount":2},"other":{"identities":[{"provider":"google","email":"r***@example.net"}],"hasActiveSubscription":false,"hostCount":1}}}}"#
    }

    private static func error(_ status: Int, _ code: String) -> BackendResponse {
        BackendResponse(status: status, body: Data(#"{"error":{"code":"\#(code)","message":"UI testing backend"}}"#.utf8))
    }

    /// 目前情境的訂閱 JSON;沒有訂閱(或轉移前屬於別人)是 `nil`。
    private var subscriptionJSON: String? {
        switch scenario {
        case .none: return nil
        case .active: return Self.subscription()
        }
    }

    private static func subscription() -> String {
        #"{"status":"active","store":"app_store","productId":"com.raychiu.purrdr.plus.yearly","expiresAt":"2099-01-01T00:00:00.000Z","gracePeriodExpiresAt":null,"willAutoRenew":true,"pendingReview":false}"#
    }

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

/// UI 測試的「後台一直沒回應」(`-uiTestingMemberLoading`):帳號頁停在第一次載入的骨架(#496)。
struct UITestingHangingBackend: BackendTransport {
    func send(_ request: BackendRequest) async throws -> BackendResponse {
        try await Task.sleep(for: .seconds(3600))
        throw BackendError.unreachable
    }
}
