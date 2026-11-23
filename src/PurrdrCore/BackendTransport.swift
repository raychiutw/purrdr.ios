import Foundation

/// 對 Purrdr 後台送 HTTP 請求的介面。
///
/// 可攜核心不直接用 `URLSession`(Android 上的 FoundationNetworking 另需驗證):iOS 的實作是
/// `PurrdrFeatures.URLSessionBackendTransport`,Android 之後再提供自己的。
public protocol BackendTransport: Sendable {
    func send(_ request: BackendRequest) async throws -> BackendResponse
}

public struct BackendRequest: Sendable, Equatable {
    public var method: String
    /// 相對於後台網址的路徑，例如 `/v1/sessions`。
    public var path: String
    /// 網址的 query(例如 `currentDeviceId`);空的不加 `?`。
    public var query: [URLQueryItem]
    public var accessToken: String?
    /// JSON body。
    public var body: Data?

    public init(method: String, path: String, query: [URLQueryItem] = [], accessToken: String? = nil, body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.accessToken = accessToken
        self.body = body
    }
}

public struct BackendResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// 後台相關的錯誤。
public enum BackendError: Error, Equatable {
    /// 後台回的錯誤(`code` 見 raychiutw/purrdr.server 的 README.md)。
    case backend(status: Int, code: String, message: String)
    /// 連不上後台。
    case unreachable
    /// 回應不是預期的格式。
    case invalidResponse
    /// 沒有登入，或登入已失效(更新權杖被拒)。
    case signedOut
    /// 409 `subscription_in_use`:這個商店訂閱已屬於另一個會員(`ownerEmail` 是遮蔽的 email;`canTransfer` 是目前會員沒有佔著有效訂閱名額)。
    case subscriptionInUse(ownerEmail: String?, canTransfer: Bool)
    /// 409 `merge_required`:連結的登入方式已屬於另一個會員。附兩邊的摘要,使用者確認後改呼叫合併。
    case mergeRequired(MemberMergeSummary)
}

/// 後台錯誤碼(`raychiutw/purrdr.server` 的 README「錯誤碼」)。app 依 `BackendError.backend` 的 `code` 判斷。
public enum BackendErrorCode {
    /// 401:更新權杖無效、過期、工作階段已撤銷,或寬限(60 秒)外重用舊權杖。**唯一**表示「要重新登入」的訊號。
    public static let invalidRefreshToken = "invalid_refresh_token"
    /// 401:存取權杖無效、過期,或會員已刪除(先換權杖重送一次)。
    public static let invalidAccessToken = "invalid_access_token"
    /// 404:登入頁(`createMember: false`)查無這個帳號的會員(#434)。
    public static let memberNotFound = "member_not_found"
    /// 409:連結時身分屬於另一個會員(`error.details` 是合併摘要)。
    public static let mergeRequired = "merge_required"
    /// 409:確認合併時兩邊都有有效訂閱。
    public static let subscriptionConflict = "subscription_conflict"
    /// 409:會員已有另一個有效訂閱。
    public static let subscriptionAlreadyActive = "subscription_already_active"
    /// 409:轉移的訂閱已屬於目前會員。
    public static let subscriptionAlreadyOwned = "subscription_already_owned"
    /// 409:訂閱已屬於另一個會員(`error.details` 是 `ownerEmail`、`canTransfer`)。
    public static let subscriptionInUse = "subscription_in_use"
    /// 404:轉移的訂閱沒登記在任何會員。
    public static let subscriptionNotFound = "subscription_not_found"
    /// 409:已經有同一種登入方式。
    public static let providerAlreadyLinked = "provider_already_linked"
    /// 400:Google Play 購買驗不過。
    public static let invalidPurchase = "invalid_purchase"
    /// 502/503:暫時問不到商店。
    public static let storeUnavailable = "store_unavailable"
}
