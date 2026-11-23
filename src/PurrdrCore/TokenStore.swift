import Foundation
import Synchronization

/// 本機存下的存取權杖與它的到期時間(重開 app 不必先換一次權杖,#406)。
public struct StoredAccessToken: Equatable, Sendable {
    public var token: String
    public var expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// 存放後台的登入資料。iOS 的實作是 Keychain(`PurrdrFeatures.KeychainTokenStore`,只在這支裝置、解鎖後可讀)。
///
/// 寫入規則(#406):**先寫新的、成功了才動舊的**;實作不可以先刪再寫,寫入失敗時舊值要原封不動。
public protocol TokenStore: Sendable {
    func refreshToken() throws -> String?
    /// `nil` 表示刪除。
    func setRefreshToken(_ token: String?) throws
    func accessToken() throws -> StoredAccessToken?
    /// `nil` 表示刪除。
    func setAccessToken(_ token: StoredAccessToken?) throws
    /// 最後一次讀到的會員(JSON,由 `MemberSession` 編解碼):連不上後台時仍知道是誰登入。`nil` 表示刪除。
    func memberSnapshot() throws -> Data?
    func setMemberSnapshot(_ snapshot: Data?) throws
}

/// 只存在記憶體的權杖存放:測試與 UI 測試模式(不碰 Keychain)使用。
public final class InMemoryTokenStore: TokenStore {
    private struct State {
        var refreshToken: String?
        var accessToken: StoredAccessToken?
        var memberSnapshot: Data?
    }

    private let state: Mutex<State>

    public init(refreshToken: String? = nil) {
        state = Mutex(State(refreshToken: refreshToken))
    }

    public func refreshToken() throws -> String? {
        state.withLock { $0.refreshToken }
    }

    public func setRefreshToken(_ token: String?) throws {
        state.withLock { $0.refreshToken = token }
    }

    public func accessToken() throws -> StoredAccessToken? {
        state.withLock { $0.accessToken }
    }

    public func setAccessToken(_ token: StoredAccessToken?) throws {
        state.withLock { $0.accessToken = token }
    }

    public func memberSnapshot() throws -> Data? {
        state.withLock { $0.memberSnapshot }
    }

    public func setMemberSnapshot(_ snapshot: Data?) throws {
        state.withLock { $0.memberSnapshot = snapshot }
    }
}
