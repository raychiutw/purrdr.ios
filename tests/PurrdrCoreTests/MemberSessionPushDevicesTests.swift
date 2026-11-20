import Foundation
import PurrdrCore
import Synchronization
import Testing

/// 通知裝置的 wire(#266,raychiutw/purrdr.server#5):清單、改名、遠端關閉，註冊配對帶裝置欄位。
@Suite("通知裝置：wire")
struct MemberSessionPushDevicesTests {
    static let thisDevice = "6f1c2a4e-3b7d-4c8e-9a10-2b3c4d5e6f70"
    static let otherDevice = "1d2e3f40-5a6b-4c7d-8e9f-0a1b2c3d4e5f"

    /// 依「方法 路徑」回固定回應的後台替身;記下送出的請求。
    final class FakeBackend: BackendTransport {
        private let replies: [String: BackendResponse]
        private let sent = Mutex<[BackendRequest]>([])

        init(_ replies: [String: BackendResponse]) {
            self.replies = replies
        }

        var requests: [BackendRequest] { sent.withLock { $0 } }

        func send(_ request: BackendRequest) async throws -> BackendResponse {
            if request.path == "/v1/sessions/refresh" {
                let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
                return BackendResponse(status: 200, body: Data(#"""
                    {"accessToken": "access-1", "accessTokenExpiresAt": "\#(expiresAt)", "refreshToken": "refresh-2",
                     "member": {"id": "6f1c2b0e-5d4a-4c7e-9a7b-3e2f1d0c9b8a", "identities": []}}
                    """#.utf8))
            }
            sent.withLock { $0.append(request) }
            return replies["\(request.method) \(request.path)"] ?? BackendResponse(status: 204, body: Data())
        }
    }

    static func json(_ status: Int, _ text: String) -> BackendResponse {
        BackendResponse(status: status, body: Data(text.utf8))
    }

    func makeSession(_ backend: FakeBackend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    @Test("註冊配對帶 deviceId、deviceName、model")
    func registeringSendsDeviceIdentity() async throws {
        let backend = FakeBackend([:])
        let session = try makeSession(backend)

        try await session.registerPushPairing(
            keyHash: "hash-1", deviceToken: "token-1", environment: .production,
            device: PushDeviceIdentity(id: PushDeviceID(rawValue: Self.thisDevice)!, name: "Ray’s iPhone", model: .iPhone))

        let body = try #require(backend.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["deviceId"] == Self.thisDevice)
        #expect(json["deviceName"] == "Ray’s iPhone")
        #expect(json["model"] == "iPhone")
        #expect(json["keyHash"] == "hash-1")
    }

    @Test("沿用舊 16 位 hex id 的裝置：後台收到 UUID 格式的值(後台只收 UUID)")
    func legacyDeviceIDIsSentInUUIDForm() async throws {
        let backend = FakeBackend([:])
        let session = try makeSession(backend)
        let legacy = try #require(PushDeviceID(rawValue: "0123456789abcdef"))

        try await session.registerPushPairing(
            keyHash: "hash-1", deviceToken: "token-1", environment: .production,
            device: PushDeviceIdentity(id: legacy, name: "iPhone", model: .iPhone))

        let body = try #require(backend.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["deviceId"] == legacy.backendValue)
        #expect(json["deviceId"] != legacy.rawValue)
    }

    @Test("註冊配對帶要收的推播種類(raychiutw/purrdr.server#10):值是 blocked、done,順序固定")
    func registrationCarriesKinds() async throws {
        let backend = FakeBackend([:])
        let session = try makeSession(backend)

        try await session.registerPushPairing(
            keyHash: "hash-1", deviceToken: "token-1", environment: .production,
            device: PushDeviceIdentity(id: PushDeviceID(rawValue: Self.thisDevice)!, name: "iPhone", model: .iPhone),
            kinds: [.done, .blocked])

        let body = try #require(backend.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kinds"] as? [String] == ["blocked", "done"])
        #expect(json["keyHash"] as? String == "hash-1")
    }

    @Test("沒指定種類時不帶 kinds:後台保留既有偏好(新配對只收 blocked)")
    func registrationWithoutKindsOmitsField() async throws {
        let backend = FakeBackend([:])
        let session = try makeSession(backend)

        try await session.registerPushPairing(
            keyHash: "hash-1", deviceToken: "token-1", environment: .production,
            device: PushDeviceIdentity(id: PushDeviceID(rawValue: Self.thisDevice)!, name: "iPhone", model: .iPhone))

        let body = try #require(backend.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["kinds"] == nil)
    }

    @Test("清單帶 currentDeviceId,舊配對的名稱與型號是 nil")
    func listsDevices() async throws {
        let backend = FakeBackend(["GET /v1/members/me/push-devices": Self.json(200, #"""
            {"devices": [
              {"deviceId": "\#(Self.thisDevice)", "name": "Ray’s iPhone", "model": "iPhone", "hostCount": 2,
               "lastRegisteredAt": 1794729600000, "current": true},
              {"deviceId": "legacy-0123456789abcdef0123456789abcdef", "name": null, "model": null, "hostCount": 1,
               "lastRegisteredAt": 1794643200000, "current": false}
            ]}
            """#)])
        let session = try makeSession(backend)

        let devices = try await session.pushDevices(currentDeviceID: Self.thisDevice)

        #expect(backend.requests.first?.query == [URLQueryItem(name: "currentDeviceId", value: Self.thisDevice)])
        #expect(devices == [
            PushDevice(
                id: Self.thisDevice, name: "Ray’s iPhone", model: .iPhone, hostCount: 2,
                lastRegisteredAt: Date(timeIntervalSince1970: 1_794_729_600), isCurrent: true),
            PushDevice(
                id: "legacy-0123456789abcdef0123456789abcdef", name: nil, model: nil, hostCount: 1,
                lastRegisteredAt: Date(timeIntervalSince1970: 1_794_643_200), isCurrent: false),
        ])
    }

    @Test("改名送 PATCH body { name },回傳改好的裝置")
    func renamesDevice() async throws {
        let backend = FakeBackend(["PATCH /v1/members/me/push-devices/\(Self.otherDevice)": Self.json(200, #"""
            {"device": {"deviceId": "\#(Self.otherDevice)", "name": "Studio iPad", "model": "iPad", "hostCount": 1,
             "lastRegisteredAt": 1794729600000, "current": false}}
            """#)])
        let session = try makeSession(backend)

        let device = try await session.renamePushDevice(Self.otherDevice, to: "Studio iPad", currentDeviceID: Self.thisDevice)

        #expect(device.name == "Studio iPad")
        #expect(device.model == .iPad)
        let request = try #require(backend.requests.first)
        #expect(request.query == [URLQueryItem(name: "currentDeviceId", value: Self.thisDevice)])
        let body = try #require(request.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["name": "Studio iPad"])
    }

    @Test("遠端關閉送 DELETE;不存在的裝置丟 device_not_found")
    func revokesDevice() async throws {
        let backend = FakeBackend([
            "DELETE /v1/members/me/push-devices/\(Self.thisDevice)":
                Self.json(404, #"{"error": {"code": "device_not_found", "message": "This device doesn't receive notifications."}}"#),
        ])
        let session = try makeSession(backend)

        try await session.revokePushDevice(Self.otherDevice)
        await #expect(throws: BackendError.backend(status: 404, code: "device_not_found", message: "This device doesn't receive notifications.")) {
            try await session.revokePushDevice(Self.thisDevice)
        }

        #expect(backend.requests.map(\.method) == ["DELETE", "DELETE"])
        #expect(backend.requests.first?.path == "/v1/members/me/push-devices/\(Self.otherDevice)")
    }
}
