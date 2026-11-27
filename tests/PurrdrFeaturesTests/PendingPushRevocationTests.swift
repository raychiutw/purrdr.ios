#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Security
import Testing

/// 推播撤銷重試(#691):撤銷後台配對失敗就把 key hash 放進待撤銷清單(Keychain),啟動與網路恢復時重送,成功才移除。
///
/// Seam:後台是 `HTTPStub`、Keychain 是 `FakeKeychain`、主機是 `FakePushPluginHost`。
@MainActor
@Suite("推播撤銷重試")
struct PendingPushRevocationTests {
    static let deviceID = PushDeviceID(rawValue: "6f1c2a4e-3b7d-4c8e-9a10-2b3c4d5e6f70")!
    static let hash = String(repeating: "a", count: 64)
    static let otherHash = String(repeating: "b", count: 64)
    static var path: String { "/v1/members/me/push-pairings/\(hash)" }

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let keychain = FakeKeychain()
    let store = InMemoryPushPairingStore()

    init() throws {
        try tokens.setRefreshToken("refresh-1")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-2", member: SubscriptionReplies.member)))
    }

    func pending() -> KeychainPendingPushRevocations { KeychainPendingPushRevocations(keychain: keychain) }

    func service() -> PushService {
        PushService(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens),
            platform: FakePushPlatform(), store: store,
            device: PushDeviceIdentity(id: Self.deviceID, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            pendingRevocations: pending(), isSignedIn: { true })
    }

    @Test("離線刪除主機:撤銷失敗進清單,連上網路後重送成功就清掉")
    func offlineDeleteQueuesThenRetries() async throws {
        backend.on("DELETE", Self.path, .unreachable)
        let service = service()
        store.setKeyHash(Self.hash, forHost: "studio")

        service.forget(hostID: "studio", installer: FakePushPluginHost().installer(deviceID: Self.deviceID))
        for _ in 0..<300 where pending().keyHashes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pending().keyHashes == [Self.hash])

        backend.on("DELETE", Self.path, .empty(204))
        await service.refreshAtLaunch()

        #expect(pending().keyHashes.isEmpty)
    }

    @Test("重送失敗就留著等下一次")
    func failedRetryKeepsEntry() async {
        backend.on("DELETE", Self.path, .unreachable)
        let service = service()
        pending().add(Self.hash)

        await service.retryPendingRevocations()

        #expect(pending().keyHashes == [Self.hash])
    }

    @Test("重送一項失敗不影響其他項:成功的移除,失敗的留著")
    func partialRetry() async {
        let otherPath = "/v1/members/me/push-pairings/\(Self.otherHash)"
        backend.on("DELETE", Self.path, .unreachable)
        backend.on("DELETE", otherPath, .empty(204))
        let service = service()
        pending().add(Self.hash)
        pending().add(Self.otherHash)

        await service.retryPendingRevocations()

        #expect(pending().keyHashes == [Self.hash])
    }

    @Test("清單存成「第一次解鎖後、僅此裝置」,不同步")
    func storedThisDeviceOnly() throws {
        pending().add(Self.hash)

        let attributes = try #require(keychain.addedAttributes.first)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(pending().keyHashes == [Self.hash])
    }

    @Test("同一個 key hash 不重複記")
    func noDuplicates() {
        pending().add(Self.hash)
        pending().add(Self.hash)
        #expect(pending().keyHashes == [Self.hash])
    }
}
#endif
