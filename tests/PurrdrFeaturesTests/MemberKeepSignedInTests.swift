import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Security
import Testing

/// 登入保留(#406、spec #402)的 model 層:網路錯誤與逾時不登出、明確拒絕才登出、重開後仍登入、「暫時連不上」狀態。
@MainActor
@Suite("會員:登入保留(model)")
struct MemberKeepSignedInTests {
    let backend = HTTPStub()
    let tokens = InMemoryTokenStore()

    func makeModel(tokens: (any TokenStore)? = nil) -> MemberModel {
        MemberModel(
            session: MemberSession(
                transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens ?? self.tokens),
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: "123-abc.apps.googleusercontent.com")))
    }

    /// 已登入過(本機有更新權杖與上次讀到的會員快照),存取權杖已過期。
    func seedSignedIn() throws {
        try tokens.setRefreshToken("refresh-0")
        try tokens.setAccessToken(StoredAccessToken(token: "access-old", expiresAt: Date(timeIntervalSince1970: 0)))
        let snapshot = #"{"id": "member-1", "identities": [{"provider": "apple", "email": "abc@privaterelay.appleid.com", "linkedAt": "2026-11-15T08:00:00.000Z"}]}"#
        try tokens.setMemberSnapshot(Data(snapshot.utf8))
    }

    @Test("開 app 時連不上後台:仍是登入狀態,標成暫時連不上,不跳提示、權杖留著")
    func offlineRestoreStaysSignedIn() async throws {
        try seedSignedIn()
        backend.on("POST", "/v1/sessions/refresh", .unreachable)
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.isConnectionLimited)
        #expect(model.notice == nil)
        #expect(try tokens.refreshToken() == "refresh-0")
    }

    @Test("後台暫時出錯(503)也一樣:保留登入")
    func serverErrorRestoreStaysSignedIn() async throws {
        try seedSignedIn()
        backend.on("POST", "/v1/sessions/refresh", .json(503, Replies.error("unavailable")))
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.isConnectionLimited)
        #expect(try tokens.refreshToken() == "refresh-0")
    }

    @Test("連得上之後再試一次:暫時連不上的狀態消失")
    func recoversWhenOnline() async throws {
        try seedSignedIn()
        backend.on("POST", "/v1/sessions/refresh", .unreachable, .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        let model = makeModel()
        await model.restore()
        try #require(model.isConnectionLimited)

        await model.restore()

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.isConnectionLimited == false)
        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("沒有會員快照(升級前登入的)又連不上:維持讀取中並提示,不當成登出")
    func offlineWithoutSnapshot() async throws {
        try tokens.setRefreshToken("refresh-0")
        backend.on("POST", "/v1/sessions/refresh", .unreachable)
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .unknown)
        #expect(try tokens.refreshToken() == "refresh-0")
    }

    @Test("登入後的操作連不上:不登出,標成暫時連不上")
    func operationOfflineKeepsSignIn() async throws {
        try seedSignedIn()
        backend.on("POST", "/v1/sessions/refresh", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))
        backend.on("DELETE", "/v1/members/me/identities/google", .unreachable)
        let model = makeModel()
        await model.restore()

        await model.unlink(.google)

        #expect(model.phase == .signedIn(Replies.expectedAppleMember))
        #expect(model.isConnectionLimited)
        #expect(try tokens.refreshToken() == "refresh-1")
    }

    @Test("後台明確拒絕(工作階段被撤銷):登出、清掉權杖與快照、提示重新登入")
    func explicitRejectionSignsOut() async throws {
        try seedSignedIn()
        backend.on("POST", "/v1/sessions/refresh", .json(401, Replies.error("invalid_refresh_token")))
        let model = makeModel()

        await model.restore()

        #expect(model.phase == .signedOut)
        #expect(model.notice == .signedOut)
        #expect(model.isConnectionLimited == false)
        #expect(try tokens.refreshToken() == nil)
        #expect(try tokens.memberSnapshot() == nil)
    }

    @Test("重開 app 仍是登入狀態:存取權杖還有效時完全不必換權杖")
    func reopenStaysSignedIn() async throws {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "refresh-1", member: Replies.appleMember)))
        let first = makeModel()
        await first.restore()
        _ = first.beginAppleAuthorization(linking: false)
        await first.completeAppleAuthorization(idToken: "t", authorizationCode: "c")
        try #require(first.phase == .signedIn(Replies.expectedAppleMember))
        backend.on("GET", "/v1/members/me", .json(200, #"{"member": \#(Replies.appleMember)}"#))

        let reopened = makeModel()
        await reopened.restore()

        #expect(reopened.phase == .signedIn(Replies.expectedAppleMember))
        #expect(backend.requests(to: "/v1/sessions/refresh").isEmpty)
    }
}

/// `KeychainTokenStore`:寫入順序與存取等級(#406)。
@Suite("會員:權杖存 Keychain")
struct KeychainTokenStoreTests {
    @Test("三個項目都是「解鎖後、僅此裝置」")
    func storesOnlyOnThisDeviceAfterFirstUnlock() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(keychain: keychain)

        try store.setRefreshToken("refresh-1")
        try store.setAccessToken(StoredAccessToken(token: "access-1", expiresAt: Date(timeIntervalSince1970: 1_794_729_600)))
        try store.setMemberSnapshot(Data("{}".utf8))

        #expect(keychain.addedAttributes.count == 3)
        for attributes in keychain.addedAttributes {
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(attributes[kSecAttrSynchronizable as String] == nil)
        }
        #expect(try store.refreshToken() == "refresh-1")
        #expect(try store.accessToken() == StoredAccessToken(token: "access-1", expiresAt: Date(timeIntervalSince1970: 1_794_729_600)))
    }

    @Test("換新權杖是原地更新,不先刪掉舊的")
    func replacesInPlaceWithoutDeleting() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(keychain: keychain)
        try store.setRefreshToken("refresh-1")

        try store.setRefreshToken("refresh-2")

        #expect(try store.refreshToken() == "refresh-2")
        #expect(keychain.deletedAccounts.isEmpty)
    }

    @Test("寫入新權杖失敗(更新被拒):舊的更新權杖還在")
    func failedUpdateKeepsOld() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(keychain: keychain)
        try store.setRefreshToken("refresh-1")
        keychain.updateStatus = errSecInteractionNotAllowed

        #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try store.setRefreshToken("refresh-2") }

        #expect(try store.refreshToken() == "refresh-1")
    }

    @Test("第一次寫入失敗(新增被拒):沒有留下半套項目,也沒有刪任何東西")
    func failedAddLeavesNothing() throws {
        let keychain = FakeKeychain()
        keychain.addStatus = errSecInteractionNotAllowed
        let store = KeychainTokenStore(keychain: keychain)

        #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try store.setRefreshToken("refresh-1") }

        #expect(try store.refreshToken() == nil)
        #expect(keychain.deletedAccounts.isEmpty)
    }

    @Test("舊版只存了更新權杖(沒有存取權杖與快照):讀得到更新權杖,其餘是沒有")
    func readsLegacyRefreshTokenOnly() throws {
        let keychain = FakeKeychain()
        keychain.items["backend.refreshToken"] = Data("legacy-refresh".utf8)
        let store = KeychainTokenStore(keychain: keychain)

        #expect(try store.refreshToken() == "legacy-refresh")
        #expect(try store.accessToken() == nil)
        #expect(try store.memberSnapshot() == nil)
    }

    @Test("讀不到(還沒第一次解鎖)時丟錯,不當成沒有登入")
    func unreadableThrows() {
        let keychain = FakeKeychain()
        keychain.copyStatus = errSecInteractionNotAllowed
        let store = KeychainTokenStore(keychain: keychain)

        #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try store.refreshToken() }
    }
}
