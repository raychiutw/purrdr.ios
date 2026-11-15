import Synchronization

/// 存放後台的更新權杖。iOS 的實作是 Keychain(`PurrdrFeatures.KeychainTokenStore`);存取權杖只放記憶體。
public protocol TokenStore: Sendable {
    func refreshToken() throws -> String?
    /// `nil` 表示刪除。
    func setRefreshToken(_ token: String?) throws
}

/// 只存在記憶體的權杖存放:測試與 UI 測試模式(不碰 Keychain)使用。
public final class InMemoryTokenStore: TokenStore {
    private let token: Mutex<String?>

    public init(refreshToken: String? = nil) {
        token = Mutex(refreshToken)
    }

    public func refreshToken() throws -> String? {
        token.withLock { $0 }
    }

    public func setRefreshToken(_ token: String?) throws {
        self.token.withLock { $0 = token }
    }
}
