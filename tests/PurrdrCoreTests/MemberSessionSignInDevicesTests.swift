import Foundation
import PurrdrCore
import Testing

/// 登入中的裝置的 wire(#409,purrdr.server README「工作階段」):清單與撤銷另一支裝置。
@Suite("登入中的裝置:wire")
struct MemberSessionSignInDevicesTests {
    typealias Backend = MemberSessionPushDevicesTests.FakeBackend

    func makeSession(_ backend: Backend) throws -> MemberSession {
        let tokens = InMemoryTokenStore()
        try tokens.setRefreshToken("refresh-1")
        return MemberSession(transport: backend, tokenStore: tokens)
    }

    @Test("清單:名稱、型號、最後上線與目前這支;沒有名稱的裝置也列出")
    func listsSignInDevices() async throws {
        let backend = Backend([
            "GET /v1/members/me/sessions": MemberSessionPushDevicesTests.json(200, #"""
                {"sessions": [
                  {"id": "s-1", "deviceId": "d-1", "deviceName": "Ray’s iPhone", "deviceModel": "iPhone", "createdAt": "2026-11-01T00:00:00.000Z",
                   "lastActiveAt": "2026-11-21T08:00:00.000Z", "expiresAt": "2027-02-01T00:00:00.000Z", "current": true},
                  {"id": "s-2", "deviceId": "d-2", "deviceName": null, "deviceModel": null, "createdAt": "2026-10-01T00:00:00.000Z",
                   "lastActiveAt": "2026-11-20T08:00:00.000Z", "expiresAt": "2027-01-01T00:00:00.000Z", "current": false}
                ]}
                """#)
        ])
        let session = try makeSession(backend)

        let devices = try await session.signInDevices()

        #expect(devices.map(\.id) == ["s-1", "s-2"])
        #expect(devices[0].name == "Ray’s iPhone")
        #expect(devices[0].model == "iPhone")
        #expect(devices[0].isCurrent)
        #expect(devices[1].name == nil)
        #expect(!devices[1].isCurrent)
        #expect(devices[0].lastActiveAt == Date(timeIntervalSince1970: 1_795_248_000))
    }

    @Test("撤銷另一支裝置:DELETE 工作階段 id")
    func revokesAnotherDevice() async throws {
        let backend = Backend([:])
        let session = try makeSession(backend)

        try await session.revokeSignInDevice("s-2")

        let request = try #require(backend.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/v1/members/me/sessions/s-2")
    }
}
