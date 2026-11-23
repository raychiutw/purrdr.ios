import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 帳號頁「登入中的裝置」(#409):清單、撤銷另一支要先確認是本人;撤銷 = 把那支裝置登出。
@MainActor
@Suite("登入中的裝置")
struct SignInDevicesModelTests {
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()

    final class Counter: @unchecked Sendable {
        var value = 0
    }

    static let sessions = #"""
        {"sessions": [
          {"id": "s-1", "deviceId": "d-1", "deviceName": "Ray’s iPhone", "deviceModel": "iPhone", "createdAt": "2026-11-01T00:00:00.000Z",
           "lastActiveAt": "2026-11-21T08:00:00.000Z", "expiresAt": "2027-02-01T00:00:00.000Z", "current": true},
          {"id": "s-2", "deviceId": "d-2", "deviceName": "Studio iPad", "deviceModel": "iPad", "createdAt": "2026-10-01T00:00:00.000Z",
           "lastActiveAt": "2026-11-20T08:00:00.000Z", "expiresAt": "2027-01-01T00:00:00.000Z", "current": false}
        ]}
        """#

    func makeModel(confirm: @escaping @MainActor @Sendable () async -> Bool = { true }) throws -> SignInDevicesModel {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
        let session = MemberSession(
            transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens)
        return SignInDevicesModel(session: session, confirmOwner: confirm)
    }

    @Test("讀取清單;沒讀過時不顯示數量")
    func loads() async throws {
        backend.on("GET", "/v1/members/me/sessions", .json(200, Self.sessions))
        let model = try makeModel()
        #expect(model.devices == nil)

        await model.load()

        #expect(model.devices?.map(\.id) == ["s-1", "s-2"])
    }

    @Test("撤銷另一支:先確認是本人,成功後從清單拿掉")
    func revokesAfterConfirmation() async throws {
        backend.on("GET", "/v1/members/me/sessions", .json(200, Self.sessions))
        backend.on("DELETE", "/v1/members/me/sessions/s-2", .json(204, ""))
        let confirmations = Counter()
        let model = try makeModel(confirm: {
            confirmations.value += 1
            return true
        })
        await model.load()
        let ipad = try #require(model.devices?.last)

        await model.revoke(ipad)

        #expect(confirmations.value == 1)
        #expect(backend.requests(to: "/v1/members/me/sessions/s-2").count == 1)
        #expect(model.devices?.map(\.id) == ["s-1"])
    }

    @Test("沒通過本人確認:不送請求、清單不變")
    func revokeNeedsOwnerConfirmation() async throws {
        backend.on("GET", "/v1/members/me/sessions", .json(200, Self.sessions))
        let model = try makeModel(confirm: { false })
        await model.load()
        let ipad = try #require(model.devices?.last)

        await model.revoke(ipad)

        #expect(backend.requests(to: "/v1/members/me/sessions/s-2").isEmpty)
        #expect(model.devices?.count == 2)
    }

    @Test("目前這支裝置不能撤銷(要登出請用登出)")
    func cannotRevokeCurrent() async throws {
        backend.on("GET", "/v1/members/me/sessions", .json(200, Self.sessions))
        let model = try makeModel()
        await model.load()
        let current = try #require(model.devices?.first)

        await model.revoke(current)

        #expect(backend.requests(to: "/v1/members/me/sessions/s-1").isEmpty)
        #expect(model.devices?.count == 2)
    }

    @Test("讀不到時保留上次的清單並說明,不是登出")
    func loadFailureKeepsList() async throws {
        backend.on("GET", "/v1/members/me/sessions", .json(200, Self.sessions), .json(503, Replies.error("store_unavailable")))
        let model = try makeModel()
        await model.load()

        await model.load()

        #expect(model.devices?.count == 2)
        #expect(model.problem != nil)
    }
}
