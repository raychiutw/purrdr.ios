#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 會員架構重做上線後,從舊版 app 升級(#414、spec #402):
/// 舊的全域通知與同步狀態被清除、舊的更新權杖被後台拒絕而要重新登入一次、重新登入後從「未開啟」開始。
///
/// Seam:後台是 `HTTPStub`(回放遷移 0009 後的行為:舊更新權杖一律 401 `invalid_refresh_token`);本機狀態是真的 `UserDefaults`(獨立 suite)。
@MainActor
@Suite("升級:清舊狀態並重新登入一次")
struct MemberUpgradeTests {
    static let keyHash = String(repeating: "a", count: 64)

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let defaults: UserDefaults
    let suite = "member-upgrade-\(UUID().uuidString)"
    let partition = MemberPartition()
    let session: MemberSession
    let localState: MemberLocalState
    let pairings: UserDefaultsPushPairingStore
    let syncStore: UserDefaultsHostSyncStore

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        session = MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens)
        localState = MemberLocalState(partition: partition, session: session)
        pairings = UserDefaultsPushPairingStore(defaults: defaults, partition: partition)
        syncStore = UserDefaultsHostSyncStore(defaults: defaults, partition: partition)
    }

    /// 0.5x 以前的狀態:沒綁會員的全域通知與同步,加上遷移前發的更新權杖(沒有會員快照)。
    func seedOldVersion() throws {
        defaults.set(["studio": Self.keyHash], forKey: "push.pairings")
        defaults.set([Self.keyHash: "token"], forKey: "push.registeredTokens")
        defaults.set(true, forKey: "hostSync.enabled")
        try tokens.setRefreshToken("old-refresh")
    }

    func makeModel() -> MemberModel {
        MemberModel(
            session: session,
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: "123-abc.apps.googleusercontent.com")),
            localState: localState)
    }

    @Test("升級後第一次開啟:舊全域狀態清掉、舊權杖被拒絕而登出並提示重新登入,重新登入後通知與同步都是未開啟")
    func upgradeClearsOldStateAndAsksForOneSignIn() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        try seedOldVersion()
        backend.on("POST", "/v1/sessions/refresh", .json(401, Replies.error("invalid_refresh_token")))
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "new-refresh", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active))
        localState.attach(push: nil, hostSync: nil, pushModels: { [] })
        let model = makeModel()

        // composition root 啟動時的順序:先清舊狀態,再讀登入狀態。
        MemberLocalState.removeLegacyGlobalState(from: defaults)
        await model.restore()

        #expect(defaults.object(forKey: "push.pairings") == nil)
        #expect(defaults.object(forKey: "push.registeredTokens") == nil)
        #expect(defaults.object(forKey: "hostSync.enabled") == nil)
        #expect(model.phase == .signedOut)
        #expect(model.notice == .signedOut)
        #expect(try tokens.refreshToken() == nil)

        // 重新登入一次:新會員的分區是空的。
        model.notice = nil
        _ = model.beginAppleAuthorization(linking: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(pairings.keyHash(forHost: "studio") == nil)
        #expect(syncStore.isEnabled == false)
        #expect(try tokens.refreshToken() == "new-refresh")
        // 只登入一次:之後換權杖成功就不再被登出。
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "new-refresh-2", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        await model.restore()
        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
    }

    @Test("升級後連不上後台:沒有會員快照時不假裝登入也不清掉權杖,連上後再處理")
    func upgradeOfflineKeepsTokenUntilBackendAnswers() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        try seedOldVersion()
        backend.on("POST", "/v1/sessions/refresh", .unreachable)
        let model = makeModel()

        await model.restore()

        #expect(model.phase != .signedIn(Replies.expectedAppleMember))
        #expect(try tokens.refreshToken() == "old-refresh")
    }
}
#endif
