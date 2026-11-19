import Foundation
import PurrdrCore

/// UI 測試的假後台(#246):`-uiTestingMember` 是已登入、未開通;`-uiTestingPlusMember` 另有有效的 Purrdr Plus。
///
/// 不連網路。只回帳號頁流程用到的路徑：換權杖、讀會員與訂閱、主機同步(回傳送來的主機)、推播配對;其餘回 404。
struct UITestingBackendTransport: BackendTransport {
    /// 啟動時就有的更新權杖(MemberSession 以它換成上面的會員)。
    static let refreshToken = "ui-testing-refresh"

    let isPlusActive: Bool

    func send(_ request: BackendRequest) async throws -> BackendResponse {
        switch (request.method, request.path) {
        case ("POST", "/v1/sessions/refresh"):
            return Self.json(#"{"accessToken":"ui-testing-access","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z","refreshToken":"\#(Self.refreshToken)","member":\#(Self.member)}"#)
        case ("GET", "/v1/members/me"):
            return Self.json(#"{"member":\#(Self.member)}"#)
        case ("GET", "/v1/members/me/subscription"):
            return Self.json(isPlusActive ? #"{"subscription":\#(Self.subscription)}"# : #"{"subscription":null}"#)
        case ("POST", "/v1/members/me/hosts/sync"):
            return Self.syncResponse(echoing: request.body)
        case ("POST", "/v1/members/me/push-pairings"), ("POST", "/v1/sessions/revoke"):
            return BackendResponse(status: 204, body: Data())
        case ("DELETE", let path) where path.hasPrefix("/v1/members/me/push-pairings/"):
            return BackendResponse(status: 204, body: Data())
        default:
            return BackendResponse(status: 404, body: Data(#"{"error":{"code":"not_found","message":"UI testing backend"}}"#.utf8))
        }
    }

    private static let member =
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
