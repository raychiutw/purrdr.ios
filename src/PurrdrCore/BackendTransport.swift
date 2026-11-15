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
    public var accessToken: String?
    /// JSON body。
    public var body: Data?

    public init(method: String, path: String, accessToken: String? = nil, body: Data? = nil) {
        self.method = method
        self.path = path
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
    /// 後台回的錯誤(`code` 見 backend/README.md)。
    case backend(status: Int, code: String, message: String)
    /// 連不上後台。
    case unreachable
    /// 回應不是預期的格式。
    case invalidResponse
    /// 沒有登入，或登入已失效(更新權杖被拒)。
    case signedOut
}
