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
    /// 這支裝置在 UI 測試的 id(composition root 帶給推播)。
    static let thisDeviceID = "5eed0000-0000-4000-8000-0000000000d1"
    static let studioIPadID = "5eed0000-0000-4000-8000-0000000000d2"
    static let legacyDeviceID = "legacy-5eed00000000000000000000000000d3"

    let isPlusActive: Bool
    /// 一開始就有更新權杖(已登入)。`false` 是 `-uiTestingSignUp`:沒登入,Apple／Google 按鈕直接以固定憑證登入這個假後台(#408)。
    let startsSignedIn: Bool

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

    init(isPlusActive: Bool, startsSignedIn: Bool = true) {
        self.isPlusActive = isPlusActive
        self.startsSignedIn = startsSignedIn
    }

    func send(_ request: BackendRequest) async throws -> BackendResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/sessions"):
            // 登入或註冊:ID token 含 `new` 的是新會員(`memberCreated: true`),其餘是既有會員。
            let idToken = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["idToken"] as? String
            let created = idToken?.contains("new") == true
            return Self.json(#"{"accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"\#(Self.refreshToken)","memberCreated":\#(created),"autoLinked":false,"member":\#(Self.memberJSON)}"#)
        case ("POST", "/v1/sessions/refresh"):
            return Self.json(#"{"accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"\#(Self.refreshToken)","member":\#(Self.memberJSON)}"#)
        case ("GET", "/v1/members/me"):
            return Self.json(#"{"member":\#(Self.memberJSON)}"#)
        case ("GET", "/v1/members/me/subscription"):
            return Self.json(isPlusActive ? #"{"subscription":\#(Self.subscription)}"# : #"{"subscription":null}"#)
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

    private static let subscription =
        #"{"status":"active","store":"app_store","productId":"com.raychiu.purrdr.plus.yearly","expiresAt":"2099-01-01T00:00:00.000Z","willAutoRenew":true}"#

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
