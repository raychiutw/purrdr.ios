import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 登入方式與合併(#410、spec #402):新增、移除、合併、衝突,而且每一步都要先確認身分。
///
/// 後台回應依 `raychiutw/purrdr.server` 的 `README.md`(合併確認、錯誤碼)手寫;
/// 身分確認用假的驗證介面(`OwnerConfirmation`),不碰 LocalAuthentication。
@MainActor
@Suite("登入方式與合併")
struct MemberMergeTests {
    let backend = HTTPStub()
    let google = HTTPStub()
    let tokens = InMemoryTokenStore()
    let owner = OwnerConfirmation()
    let partition = MemberPartition()
    let session: MemberSession
    let localState: MemberLocalState

    init() {
        session = MemberSession(
            transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens)
        localState = MemberLocalState(partition: partition, session: session)
    }

    func makeModel(confirm: Bool = true) -> MemberModel {
        owner.approves = confirm
        return MemberModel(
            session: session,
            google: GoogleSignIn(
                configuration: GoogleSignIn.Configuration(
                    clientID: "123-abc.apps.googleusercontent.com",
                    authorizationEndpoint: URL(string: "https://accounts.google.test/o/oauth2/v2/auth")!,
                    tokenEndpoint: google.baseURL.appending(path: "token")
                ),
                session: google.urlSession
            ),
            localState: localState,
            confirmOwner: { [owner] in owner.confirm() }
        )
    }

    /// 已用 Apple 登入(存取權杖 `access-1`)。
    func signedInModel(confirm: Bool = true) async throws -> MemberModel {
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        let model = makeModel(confirm: confirm)
        await model.restore()
        try #require(model.phase == .signedIn(Replies.expectedAppleMember))
        owner.count = 0
        return model
    }

    /// 連結 Google 時發現它已屬於另一個會員(後台回合併確認摘要)。
    func replyMergeRequired(canMerge: Bool = true) {
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))
        backend.on("POST", "/v1/members/me/identities", .json(409, MergeReplies.mergeRequired(canMerge: canMerge)))
    }

    // MARK: - 新增

    @Test("新增登入方式要先確認身分,確認過才送出連結")
    func linkingConfirmsOwnerFirst() async throws {
        let model = try await signedInModel()
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))
        backend.on("POST", "/v1/members/me/identities", .json(200, #"{"member": \#(Replies.linkedMember), "mergedMemberId": null}"#))

        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)

        #expect(owner.count == 1)
        guard case .signedIn(let member) = model.phase else { Issue.record("應該仍是登入狀態"); return }
        #expect(member.identities.map(\.method) == [.apple, .google])
        #expect(model.pendingMerge == nil)
    }

    @Test("身分確認被取消:不送出連結,會員不變")
    func linkingDeniedSendsNothing() async throws {
        let model = try await signedInModel(confirm: false)
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))

        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)

        #expect(backend.requests(to: "/v1/members/me/identities").isEmpty)
        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.notice == nil)
    }

    // MARK: - 發現已屬另一個會員

    @Test("新增時身分已屬於另一個會員:不提示錯誤,留下兩邊摘要等使用者確認合併")
    func linkFoundAnotherMember() async throws {
        let model = try await signedInModel()
        replyMergeRequired()

        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)

        #expect(model.notice == nil)
        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        let proposal = try #require(model.pendingMerge)
        #expect(proposal.summary.canMerge)
        #expect(proposal.summary.current.identities == [.init(method: .apple, email: "a***@privaterelay.appleid.com")])
        #expect(proposal.summary.current.hasActiveSubscription)
        #expect(proposal.summary.current.hostCount == 2)
        #expect(proposal.summary.other.identities == [.init(method: .google, email: "c***@gmail.com")])
        #expect(proposal.summary.other.hasActiveSubscription == false)
        #expect(proposal.summary.other.hostCount == 1)
    }

    @Test("確認合併:再確認一次身分,帶剛驗證的憑證呼叫合併,換上留下會員的新存取權杖")
    func confirmMerge() async throws {
        let model = try await signedInModel()
        replyMergeRequired()
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        owner.count = 0
        backend.on("POST", "/v1/members/me/identities/merge", .json(200, MergeReplies.merged(accessToken: "access-merged")))

        await model.confirmMerge()

        #expect(owner.count == 1)
        let request = try #require(backend.requests(to: "/v1/members/me/identities/merge").first)
        #expect(request.json?["provider"] as? String == "google")
        #expect(request.json?["idToken"] as? String == "google-id-token")
        #expect(model.pendingMerge == nil)
        #expect(model.notice == .merged)
        guard case .signedIn(let member) = model.phase else { Issue.record("應該登入"); return }
        #expect(member.id == "member-2")
        #expect(member.identities.map(\.method) == [.apple, .google])
        // 原本的存取權杖屬於被刪的會員,換成回應附的新權杖(存進權杖存放);更新權杖不變。
        #expect(try tokens.accessToken()?.token == "access-merged")
        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("合併時身分確認被取消:不呼叫合併,摘要保留可再試")
    func mergeDeniedKeepsProposal() async throws {
        let model = try await signedInModel()
        replyMergeRequired()
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        owner.approves = false

        await model.confirmMerge()

        #expect(backend.requests(to: "/v1/members/me/identities/merge").isEmpty)
        #expect(model.pendingMerge != nil)
    }

    @Test("兩邊都有有效訂閱(canMerge 為 false):不能確認合併,不送請求")
    func cannotMergeWithTwoSubscriptions() async throws {
        let model = try await signedInModel()
        replyMergeRequired(canMerge: false)
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)

        await model.confirmMerge()

        #expect(model.pendingMerge?.summary.canMerge == false)
        #expect(backend.requests(to: "/v1/members/me/identities/merge").isEmpty)
    }

    @Test("確認合併時後台回 subscription_conflict:說明要先取消其中一個,摘要收起")
    func mergeSubscriptionConflict() async throws {
        let model = try await signedInModel()
        replyMergeRequired()
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        backend.on("POST", "/v1/members/me/identities/merge", .json(409, Replies.error("subscription_conflict")))

        await model.confirmMerge()

        #expect(model.notice == .subscriptionConflict)
        #expect(model.pendingMerge == nil)
        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
    }

    @Test("確認合併時已經有同一種登入方式(provider_already_linked):提示已連結,摘要收起")
    func mergeProviderAlreadyLinked() async throws {
        let model = try await signedInModel()
        replyMergeRequired()
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        backend.on("POST", "/v1/members/me/identities/merge", .json(409, Replies.error("provider_already_linked")))

        await model.confirmMerge()

        #expect(model.notice == .methodAlreadyLinked)
        #expect(model.pendingMerge == nil)
    }

    @Test("取消合併:收起摘要,什麼都不送")
    func cancelMerge() async throws {
        let model = try await signedInModel()
        replyMergeRequired()
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)

        model.cancelMerge()

        #expect(model.pendingMerge == nil)
        #expect(backend.requests(to: "/v1/members/me/identities/merge").isEmpty)
    }

    // MARK: - 移除

    @Test("移除登入方式要先確認身分,確認過才送出")
    func unlinkConfirmsOwnerFirst() async throws {
        let model = try await signedInModel()
        backend.on("POST", "/v1/members/me/identities", .json(200, #"{"member": \#(Replies.linkedMember), "mergedMemberId": null}"#))
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        owner.count = 0
        backend.on("DELETE", "/v1/members/me/identities/google", .json(200, #"{"member": \#(Replies.appleMember)}"#))

        await model.unlink(.google)

        #expect(owner.count == 1)
        #expect(backend.requests(to: "/v1/members/me/identities/google").count == 1)
        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
    }

    @Test("移除時身分確認被取消:不送出")
    func unlinkDeniedSendsNothing() async throws {
        let model = try await signedInModel()
        backend.on("POST", "/v1/members/me/identities", .json(200, #"{"member": \#(Replies.linkedMember), "mergedMemberId": null}"#))
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        owner.approves = false
        backend.on("DELETE", "/v1/members/me/identities/google", .json(200, #"{"member": \#(Replies.appleMember)}"#))

        await model.unlink(.google)

        #expect(backend.requests(to: "/v1/members/me/identities/google").isEmpty)
    }

    @Test("只剩一種登入方式時不能移除:不問身分、不送請求")
    func cannotUnlinkTheOnlyMethod() async throws {
        let model = try await signedInModel()
        #expect(model.canUnlink == false)

        await model.unlink(.apple)

        #expect(owner.count == 0)
        #expect(backend.requests(to: "/v1/members/me/identities/apple").isEmpty)
        #expect(model.notice == .failed("Keep at least one sign-in method."))
    }

    @Test("合併後留下的是對方會員:本機分區改成新會員(不再是被刪的會員)")
    func mergeMovesPartitionToKeptMember() async throws {
        let model = try await signedInModel()
        #expect(partition.memberID == "member-1")
        replyMergeRequired()
        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)
        backend.on("POST", "/v1/members/me/identities/merge", .json(200, MergeReplies.merged(accessToken: "access-merged")))

        await model.confirmMerge()

        #expect(partition.memberID == "member-2")
    }

    // MARK: - 訂閱屬於別的會員

    @Test("後台回 subscription_in_use:顯示訂閱屬於另一個會員,不是泛用錯誤")
    func subscriptionInUseHasItsOwnNotice() async throws {
        let model = try await signedInModel()
        google.on("POST", "/token", .json(200, #"{"id_token": "google-id-token"}"#))
        backend.on(
            "POST", "/v1/members/me/identities",
            .json(409, #"{"error": {"code": "subscription_in_use", "message": "x", "details": {"ownerEmail": "r***@icloud.com", "canTransfer": true}}}"#))

        await model.linkGoogle(browser: MemberModelTests.approvingBrowser)

        #expect(model.notice == .subscriptionInUse)
    }
}

/// 假的身分確認(取代系統驗證介面):記錄被問了幾次,可設定同意或取消。
@MainActor
final class OwnerConfirmation {
    var approves = true
    var count = 0

    func confirm() -> Bool {
        count += 1
        return approves
    }
}

/// 合併確認相關的後台回應(`raychiutw/purrdr.server` 的 README「合併確認」)。
enum MergeReplies {
    static func mergeRequired(canMerge: Bool = true) -> String {
        #"""
        {"error": {"code": "merge_required", "message": "That sign-in method belongs to another member.",
          "details": {"canMerge": \#(canMerge),
            "current": {"identities": [{"provider": "apple", "email": "a***@privaterelay.appleid.com"}], "hasActiveSubscription": true, "hostCount": 2},
            "other": {"identities": [{"provider": "google", "email": "c***@gmail.com"}], "hasActiveSubscription": \#(!canMerge), "hostCount": 1}}}}
        """#
    }

    /// 合併成功:留下的是對方(member-2),原本的存取權杖屬於被刪的 member-1,所以附新的存取權杖。
    static func merged(accessToken: String) -> String {
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
        return #"""
        {"member": {"id": "member-2", "identities": [
          {"provider": "apple", "email": "abc@privaterelay.appleid.com", "linkedAt": "2026-11-15T08:00:00.000Z"},
          {"provider": "google", "email": "cat@gmail.com", "linkedAt": "2026-11-15T09:00:00.000Z"}]},
         "mergedMemberId": "member-1", "accessToken": "\#(accessToken)", "accessTokenExpiresAt": "\#(expiresAt)"}
        """#
    }
}
