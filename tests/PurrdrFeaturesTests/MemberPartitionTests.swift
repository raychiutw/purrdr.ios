#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 通知與主機同步的本機狀態依會員分區(#405、spec #402):
/// 新會員從未開啟開始、登出與換會員前先撤銷這支裝置的推播配對再清除分區、升級時清掉舊的全域狀態。
///
/// Seam:後台是 `HTTPStub`;主機是 `LocalShellHost`(暫存家目錄,herdr 換成 `FakeHerdrPluginCLI`);通知權限是 `FakePushPlatform`。
@MainActor
final class RequestCountBox: @unchecked Sendable { var value = 0 }

@MainActor
@Suite("本機狀態依會員分區")
struct MemberPartitionTests {
    static let deviceID = PushDeviceID(rawValue: "0123456789abcdef")!
    static let keyHashA = String(repeating: "a", count: 64)
    static let keyHashB = String(repeating: "b", count: 64)

    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()
    let platform = FakePushPlatform()
    let partition = MemberPartition()
    let pairings: InMemoryPushPairingStore
    let syncStore: InMemoryHostSyncStore
    let session: MemberSession
    let localState: MemberLocalState
    let hostStore = MemoryHostStore()

    init() throws {
        pairings = InMemoryPushPairingStore(partition: partition)
        syncStore = InMemoryHostSyncStore(partition: partition)
        session = MemberSession(transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens)
        localState = MemberLocalState(partition: partition, session: session)
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        backend.on("DELETE", "/v1/members/me", .json(200, #"{"deleted": true}"#))
        backend.on("POST", "/v1/sessions/revoke", .json(200, "{}"))
        backend.on("GET", "/v1/members/me/subscription", .json(200, SubscriptionReplies.active))
        platform.token = PushModelTests.token
    }

    func pushService(pending: any PendingPushRevocations = InMemoryPendingPushRevocations()) -> PushService {
        PushService(
            session: session, platform: platform, store: pairings,
            device: PushDeviceIdentity(id: Self.deviceID, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(
                endpoint: PushModelTests.endpoint, environment: .production, pluginSource: "raychiutw/purrdr.host/host-plugin"),
            pendingRevocations: pending, isSignedIn: { true })
    }

    func makeSync() -> HostSyncModel {
        let hosts = HostsModel(
            store: hostStore, demoChannel: FakeHost(), credentials: HostCredentials(secrets: EphemeralHostSecretStore(), deviceKey: EphemeralDeviceKey()),
            hostService: HostServiceAccess(tokens: InMemoryDeviceTokenStore()), makeChannel: { _, _, _ in FakeHost() })
        hosts.load()
        return HostSyncModel(session: session, plus: SubscriptionModel(session: session, store: FakePlusStore()), hosts: hosts, store: syncStore)
    }

    func makeMemberModel(confirmOwner: (@MainActor @Sendable () async -> Bool)? = nil) -> MemberModel {
        MemberModel(
            session: session,
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: "123-abc.apps.googleusercontent.com")),
            localState: localState, confirmOwner: confirmOwner)
    }

    /// 這個會員在 studio 開了通知、也開了主機同步(只動本機紀錄)。
    func seedNotificationsAndSync(keyHash: String = keyHashA) {
        pairings.setKeyHash(keyHash, forHost: "studio")
        syncStore.isEnabled = true
        syncStore.journal.recordSave(UUID(), at: Date(timeIntervalSince1970: 1_794_729_600))
    }

    // MARK: - 分區

    @Test("新會員一律從未開啟開始:換會員後看不到上一位的通知與同步")
    func newMemberStartsOff() {
        partition.activate("member-a")
        seedNotificationsAndSync()

        partition.activate("member-b")

        #expect(pairings.keyHash(forHost: "studio") == nil)
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
        #expect(syncStore.journal == HostSyncJournal())
    }

    @Test("沒有會員時:讀到空的、寫入不留下")
    func noMemberHoldsNothing() {
        pairings.setKeyHash(Self.keyHashA, forHost: "studio")
        syncStore.isEnabled = true

        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
        partition.activate("member-a")
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
    }

    @Test("同一個會員回來時,自己的分區還在")
    func samePartitionSurvivesReactivation() {
        partition.activate("member-a")
        seedNotificationsAndSync()
        partition.activate(nil)
        partition.activate("member-a")

        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(syncStore.isEnabled)
    }

    @Test("UserDefaults 版:也依會員分區,換會員看不到上一位的")
    func userDefaultsStoresArePartitioned() throws {
        let suite = "member-partition-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let partition = MemberPartition()
        let pushStore = UserDefaultsPushPairingStore(defaults: defaults, partition: partition)
        let syncStore = UserDefaultsHostSyncStore(defaults: defaults, partition: partition)

        partition.activate("member-a")
        pushStore.setKeyHash(Self.keyHashA, forHost: "studio")
        pushStore.setRegisteredToken("token", forKeyHash: Self.keyHashA)
        pushStore.setKinds([.blocked], forKeyHash: Self.keyHashA)
        syncStore.isEnabled = true
        partition.activate("member-b")

        #expect(pushStore.pairings.isEmpty)
        #expect(pushStore.registeredTokens.isEmpty)
        #expect(pushStore.kinds(forKeyHash: Self.keyHashA) == nil)
        #expect(syncStore.isEnabled == false)
        partition.activate("member-a")
        #expect(pushStore.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(syncStore.isEnabled)
    }

    // MARK: - 合併(#410)

    @Test("合併後留下的是另一個會員:通知與同步紀錄搬到新會員的分區,原會員的分區不留")
    func mergeMovesRecordsToKeptMember() {
        let push = pushService()
        let sync = makeSync()
        localState.attach(push: push, hostSync: sync, pushModels: { [] })
        localState.activate(Replies.expectedAppleMember)
        seedNotificationsAndSync()
        let journal = syncStore.journal

        localState.migrate(to: Replies.expectedGoogleMember)

        #expect(partition.memberID == "member-2")
        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(syncStore.isEnabled)
        #expect(syncStore.journal == journal)
        partition.activate("member-1")
        #expect(pairings.pairings.isEmpty, "被刪的會員不該留下本機紀錄")
        #expect(syncStore.isEnabled == false)
    }

    @Test("UserDefaults 版:搬分區帶走配對、註冊 token、種類與同步紀錄")
    func userDefaultsMovePartition() throws {
        let suite = "member-partition-move-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let partition = MemberPartition()
        let pushStore = UserDefaultsPushPairingStore(defaults: defaults, partition: partition)
        let syncStore = UserDefaultsHostSyncStore(defaults: defaults, partition: partition)
        partition.activate("member-a")
        pushStore.setKeyHash(Self.keyHashA, forHost: "studio")
        pushStore.setRegisteredToken("token", forKeyHash: Self.keyHashA)
        pushStore.setKinds([.blocked], forKeyHash: Self.keyHashA)
        syncStore.isEnabled = true
        syncStore.journal.recordSave(UUID(), at: Date(timeIntervalSince1970: 1_794_729_600))
        let journal = syncStore.journal

        pushStore.movePartition(from: "member-a", to: "member-b")
        syncStore.movePartition(from: "member-a", to: "member-b")
        partition.activate("member-b")

        #expect(pushStore.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(pushStore.registeredTokens[Self.keyHashA] == "token")
        #expect(pushStore.kinds(forKeyHash: Self.keyHashA) == [.blocked])
        #expect(syncStore.isEnabled)
        #expect(syncStore.journal == journal)
        partition.activate("member-a")
        #expect(pushStore.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
    }

    // MARK: - 升級

    @Test("升級時舊的全域狀態被清除")
    func legacyGlobalStateIsRemovedOnUpgrade() throws {
        let suite = "member-partition-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["studio": Self.keyHashA], forKey: "push.pairings")
        defaults.set([Self.keyHashA: "token"], forKey: "push.registeredTokens")
        defaults.set([Self.keyHashA: ["blocked"]], forKey: "push.kinds")
        defaults.set(true, forKey: "hostSync.enabled")
        defaults.set(Data("{}".utf8), forKey: "hostSync.journal")
        defaults.set("unrelated", forKey: "appearance")
        // 新格式(已分區)的紀錄不能被一起清掉。
        let partition = MemberPartition()
        partition.activate("member-a")
        let store = UserDefaultsPushPairingStore(defaults: defaults, partition: partition)
        store.setKeyHash(Self.keyHashB, forHost: "lab")

        MemberLocalState.removeLegacyGlobalState(from: defaults)

        for key in ["push.pairings", "push.registeredTokens", "push.kinds", "hostSync.enabled", "hostSync.journal"] {
            #expect(defaults.object(forKey: key) == nil, "\(key) 應被清除")
        }
        #expect(defaults.string(forKey: "appearance") == "unrelated")
        #expect(store.keyHash(forHost: "lab") == Self.keyHashB)
    }

    // MARK: - 登出與換會員

    @Test("登出:先撤銷這支裝置的推播配對(後台收到請求),再登出,最後清除該會員分區")
    func signOutRevokesPairingsThenClears() async throws {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        let member = makeMemberModel()
        let push = pushService()
        let sync = makeSync()
        localState.attach(push: push, hostSync: sync, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        push.reloadModels()
        sync.reload()
        let pushModel = PushModel(service: push, hostID: "studio", installer: nil, muted: { [] })
        #expect(pushModel.state == .on)
        #expect(sync.isEnabled)

        await member.signOut()

        #expect(member.phase == .signedOut)
        let order = backend.requests.map { "\($0.method) \($0.path)" }
        let revoke = try #require(order.firstIndex(of: "DELETE /v1/members/me/push-pairings/\(Self.keyHashA)"))
        let signOut = try #require(order.firstIndex(of: "POST /v1/sessions/revoke"))
        #expect(revoke < signOut, "推播配對要在登出前撤銷(登出後就沒有權杖了)")
        #expect(pairings.pairings.isEmpty)
        #expect(sync.isEnabled == false)
        #expect(syncStore.isEnabled == false)
        #expect(sync.status == .off)
        // 重新登入同一個會員:分區已清除,從未開啟開始。
        partition.activate("member-1")
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.journal == HostSyncJournal(), "同步紀錄也要清除")
    }

    @Test("離開會員(leave)清除該會員的分區:同一個會員之後回來也是從未開啟開始")
    func leaveClearsThatMembersPartition() async {
        let push = pushService()
        let sync = makeSync()
        localState.attach(push: push, hostSync: sync, pushModels: { [] })
        localState.activate(Replies.expectedAppleMember)
        seedNotificationsAndSync()
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))

        let left = await localState.leave()

        #expect(left)
        partition.activate(Replies.expectedAppleMember.id)
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
        #expect(syncStore.journal == HostSyncJournal())
    }

    @Test("leave(force:):連不上後台時一般離開不清除、強制離開照樣清除本機配對與分區(#420)")
    func leaveForceClearsEvenWhenBackendUnreachable() async {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .unreachable)
        let member = makeMemberModel()
        localState.attach(push: pushService(), hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()

        #expect(await localState.leave() == false)
        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(partition.memberID != nil)

        #expect(await localState.leave(force: true) == true)
        #expect(pairings.pairings.isEmpty)
        #expect(partition.memberID != nil, "分區的清除是移除該會員的儲存狀態,memberID 由 discardAll 之後才歸零")
    }

    @Test("登出:主機上的配對檔也移除(PushModel 關閉),後台配對只撤銷一次")
    func signOutRemovesHostPairingToo() async throws {
        let host = try LocalShellHost.temporary()
        try FakeHerdrPluginCLI.install(on: host)
        backend.on("POST", "/v1/members/me/push-pairings", .json(201, #"{"registered":true}"#))
        let member = makeMemberModel()
        let push = pushService()
        localState.attach(push: push, hostSync: nil, pushModels: { [] })
        await member.restore()
        let pushModel = PushModel(
            service: push, hostID: "studio", installer: push.sshInstaller(channel: host, herdr: HerdrInstallation()), muted: { [] })
        await pushModel.requestOn()
        await pushModel.confirm()
        try #require(pushModel.state == .on)
        let pairingFile = host.url(".purrdr/push-0123456789abcdef/pairing")
        try #require(FileManager.default.fileExists(atPath: pairingFile.path))
        let keyHash = try #require(pairings.keyHash(forHost: "studio"))
        backend.on("DELETE", "/v1/members/me/push-pairings/\(keyHash)", .json(200, #"{"revoked":true}"#))
        localState.attach(push: push, hostSync: nil, pushModels: { [pushModel] })

        await member.signOut()

        #expect(!FileManager.default.fileExists(atPath: pairingFile.path))
        #expect(pushModel.state == .off)
        #expect(backend.requests(to: "/v1/members/me/push-pairings/\(keyHash)").count == 1)
        #expect(pairings.pairings.isEmpty)
    }

    @Test("強制離開時後台撤銷失敗:key hash 進待撤銷清單,之後重送(#691)")
    func forceLeaveQueuesFailedRevocation() async {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .unreachable)
        let pending = InMemoryPendingPushRevocations()
        let push = pushService(pending: pending)
        let member = makeMemberModel()
        localState.attach(push: push, hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()

        #expect(await localState.leave(force: true) == true)
        #expect(pending.keyHashes == [Self.keyHashA])

        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        await push.retryPendingRevocations()
        #expect(pending.keyHashes.isEmpty)
    }

    @Test("撤銷後台配對連不上時不登出:通知配對仍有效,不能假裝登出了")
    func signOutStopsWhenRevokeCannotReachBackend() async {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .unreachable)
        let member = makeMemberModel()
        let push = pushService()
        localState.attach(push: push, hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()

        await member.signOut()

        guard case .signedIn = member.phase else {
            Issue.record("連不上後台撤銷配對時不應登出,phase 是 \(member.phase)")
            return
        }
        #expect(member.notice == .signOutBackendUnreachable)
        #expect(backend.requests(to: "/v1/sessions/revoke").isEmpty)
        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
    }

    @Test("登出(非 force)連不上後台:不改任何本機狀態——主機同步仍開、配對仍在，選取消後維持原狀")
    func signOutUnreachableLeavesLocalStateUntouched() async {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .unreachable)
        backend.on("GET", "/v1/members/me", .unreachable)
        let member = makeMemberModel()
        await member.restore()
        seedNotificationsAndSync()
        let sync = makeSync()
        sync.reload()
        localState.attach(push: pushService(), hostSync: sync, pushModels: { [] })

        await member.signOut()

        #expect(member.notice == .signOutBackendUnreachable)
        #expect(syncStore.isEnabled == true, "連不上後台就不該先停掉主機同步")
        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(sync.isEnabled, "主機同步的開關也不能被先關掉")
    }

    @Test("連不上後台時選「仍要登出」:登出成功並清掉本機分區,後台配對留待之後處理(#420)")
    func forceSignOutClearsLocalPartitionWhenBackendUnreachable() async {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .unreachable)
        let member = makeMemberModel()
        let push = pushService()
        localState.attach(push: push, hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()

        await member.signOut()
        member.notice = nil
        await member.signOut(force: true)

        #expect(member.phase == .signedOut)
        #expect(backend.requests(to: "/v1/sessions/revoke").count == 1)
        #expect(pairings.keyHash(forHost: "studio") == nil)
        #expect(partition.memberID == nil)
    }

    @Test("刪除會員:刪除請求成功後才清除本機分區與配對,主機同步一併關閉")
    func deleteMemberClearsLocalStateAfterRequestSucceeds() async throws {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        let member = makeMemberModel()
        let push = pushService()
        localState.attach(push: push, hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()

        await member.deleteMember()

        #expect(backend.requests(to: "/v1/members/me").count >= 1)
        #expect(member.phase == .signedOut)
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
    }

    @Test("刪除會員:刪除請求失敗(連不上)時仍是登入,通知配對與主機同步都沒被清掉")
    func deleteMemberFailureKeepsLocalState() async {
        backend.on("DELETE", "/v1/members/me", .unreachable)
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        let member = makeMemberModel()
        let sync = makeSync()
        localState.attach(push: pushService(), hostSync: sync, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        sync.reload()

        await member.deleteMember()

        guard case .signedIn = member.phase else { Issue.record("刪除失敗不應登出,phase 是 \(member.phase)"); return }
        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
        #expect(syncStore.isEnabled == true)
        #expect(partition.memberID != nil)
    }

    // MARK: - 登出與刪除要先確認身分(#412)

    @Test("登出:身分確認沒過(取消或失敗)什麼都不送、不清除,仍是登入")
    func signOutDoesNothingWhenOwnerNotConfirmed() async {
        let member = makeMemberModel(confirmOwner: { false })
        localState.attach(push: pushService(), hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        let before = backend.requests.count

        await member.signOut()

        guard case .signedIn = member.phase else { Issue.record("身分沒確認不應登出"); return }
        #expect(backend.requests.count == before, "沒確認身分不能送任何請求(含撤銷配對)")
        #expect(pairings.keyHash(forHost: "studio") == Self.keyHashA)
    }

    @Test("身分確認沒過(取消或失敗):登出與刪除都要提示，不能無聲失效")
    func ownerNotConfirmedShowsNotice() async {
        let member = makeMemberModel(confirmOwner: { false })
        localState.attach(push: pushService(), hostSync: nil, pushModels: { [] })
        await member.restore()

        await member.signOut()
        guard case .failed = member.notice else { Issue.record("登出被擋應有提示:\(String(describing: member.notice))"); return }
        member.notice = nil

        await member.deleteMember()
        guard case .failed = member.notice else { Issue.record("刪除被擋應有提示:\(String(describing: member.notice))"); return }
    }

    @Test("沒有裝置密碼(無法驗證):刪除說明要提到無法確認身分")
    func deleteExplainsWhenOwnerCannotBeVerified() {
        let unverifiable = MemberModel(
            session: session,
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: "123-abc.apps.googleusercontent.com")),
            localState: localState, ownerVerificationAvailable: { false })
        #expect(unverifiable.canVerifyOwner == false)
        #expect(makeMemberModel().canVerifyOwner == true)
    }

    @Test("登出:身分確認先於撤銷配對與登出")
    func signOutConfirmsOwnerBeforeRevoking() async throws {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        let seen = RequestCountBox()
        let member = makeMemberModel(confirmOwner: { [backend] in seen.value = backend.requests.count; return true })
        localState.attach(push: pushService(), hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        let before = backend.requests.count

        await member.signOut()

        #expect(member.phase == .signedOut)
        #expect(seen.value == before, "確認身分時還沒有任何撤銷請求")
        #expect(backend.requests(to: "/v1/sessions/revoke").count == 1)
    }

    @Test("刪除會員:身分確認沒過什麼都不送;通過後才刪除並清掉本機配對")
    func deleteMemberConfirmsOwnerFirst() async throws {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        let allowed = RequestCountBox()
        let member = makeMemberModel(confirmOwner: { allowed.value == 1 })
        localState.attach(push: pushService(), hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        let before = backend.requests.count

        await member.deleteMember()
        #expect(backend.requests.count == before)
        guard case .signedIn = member.phase else { Issue.record("身分沒確認不應刪除"); return }

        allowed.value = 1
        await member.deleteMember()
        let order = backend.requests.map { "\($0.method) \($0.path)" }
        #expect(order.contains("DELETE /v1/members/me"))
        #expect(member.phase == .signedOut)
        #expect(pairings.pairings.isEmpty)
    }

    @Test("連不上後台時「仍要登出」不再要求第二次身分確認(第一次已確認過)")
    func forceSignOutDoesNotAskAgain() async {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .unreachable)
        let asked = RequestCountBox()
        let member = makeMemberModel(confirmOwner: { asked.value += 1; return true })
        localState.attach(push: pushService(), hostSync: nil, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()

        await member.signOut()
        member.notice = nil
        await member.signOut(force: true)

        #expect(asked.value == 1)
        #expect(member.phase == .signedOut)
    }

    @Test("換會員登入:新會員從未開啟開始,上一位的推播配對已撤銷")
    func switchingMemberRevokesPreviousAndStartsOff() async throws {
        backend.on("DELETE", "/v1/members/me/push-pairings/\(Self.keyHashA)", .json(200, #"{"revoked":true}"#))
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-2", member: Replies.googleMember)))
        let member = makeMemberModel()
        let push = pushService()
        let sync = makeSync()
        localState.attach(push: push, hostSync: sync, pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        push.reloadModels()
        sync.reload()

        _ = member.beginAppleAuthorization(linking: false)
        await member.completeAppleAuthorization(idToken: "other-id-token", authorizationCode: "code")

        #expect(member.phase == .signedIn(Replies.expectedGoogleMember))
        #expect(backend.requests(to: "/v1/members/me/push-pairings/\(Self.keyHashA)").count == 1)
        #expect(pairings.pairings.isEmpty)
        #expect(sync.isEnabled == false)
        #expect(syncStore.isEnabled == false)
        let order = backend.requests.map { "\($0.method) \($0.path)" }
        let revoke = try #require(order.firstIndex(of: "DELETE /v1/members/me/push-pairings/\(Self.keyHashA)"))
        let signIn = try #require(order.firstIndex(of: "POST /v1/sessions"))
        #expect(revoke < signIn)
    }

    @Test("登入失效(後台撤銷了工作階段)時清掉本機分區,下一位不會看到")
    func remoteSignOutDiscardsPartition() async throws {
        let member = makeMemberModel()
        let push = pushService()
        localState.attach(push: push, hostSync: makeSync(), pushModels: { [] })
        await member.restore()
        seedNotificationsAndSync()
        backend.on("POST", "/v1/sessions/refresh", .json(401, Replies.error("invalid_refresh_token")))
        backend.on("DELETE", "/v1/members/me/identities/google", .json(401, Replies.error("invalid_access_token")))

        await member.unlink(.google)

        #expect(member.phase == .signedOut)
        partition.activate("member-1")
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
        #expect(syncStore.journal == HostSyncJournal())
    }

    @Test("冷啟動時已登出(登入已失效):清掉殘留的會員分區")
    func coldStartSignedOutDiscardsPartition() async {
        partition.activate("member-1")
        seedNotificationsAndSync()
        partition.activate(nil)
        try? tokens.setRefreshToken(nil)
        let member = makeMemberModel()
        localState.attach(push: pushService(), hostSync: makeSync(), pushModels: { [] })

        await member.restore()

        #expect(member.phase == .signedOut)
        partition.activate("member-1")
        #expect(pairings.pairings.isEmpty)
        #expect(syncStore.isEnabled == false)
        #expect(syncStore.journal == HostSyncJournal())
    }
}
#endif
