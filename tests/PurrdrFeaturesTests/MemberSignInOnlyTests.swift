import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 登入頁查無會員(#434 第 1 項、#408):「登入」不新建會員,查無時擋下並詢問要不要加入。
///
/// 後台目前沒有「不新建」選項(purrdr.server 的 `POST /v1/sessions` 查無會員一律新建),
/// 所以 app 端以 `MemberSession(supportsSignInOnly:)` 控制,預設關閉;這裡用假後台模擬「後台支援」的情況。
@MainActor
@Suite("登入頁查無會員")
struct MemberSignInOnlyTests {
    let backend = HTTPStub()
    let google = HTTPStub()
    let tokens = InMemoryTokenStore()

    func makeModel(supportsSignInOnly: Bool = true) -> MemberModel {
        MemberModel(
            session: MemberSession(
                transport: URLSessionBackendTransport(baseURL: backend.baseURL, session: backend.urlSession), tokenStore: tokens,
                supportsSignInOnly: supportsSignInOnly),
            google: GoogleSignIn(
                configuration: GoogleSignIn.Configuration(
                    clientID: "123-abc.apps.googleusercontent.com",
                    authorizationEndpoint: URL(string: "https://accounts.google.test/o/oauth2/v2/auth")!,
                    tokenEndpoint: google.baseURL.appending(path: "token")),
                session: google.urlSession))
    }

    @Test("登入(不新建)查無會員:不登入、不提示錯誤,改問要不要加入")
    func signInWithoutMemberAsksToJoin() async throws {
        backend.on("POST", "/v1/sessions", .json(404, Replies.error("member_not_found")))
        let model = makeModel()
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false, joining: false)
        await model.completeAppleAuthorization(idToken: "apple-id-token", authorizationCode: "apple-code")

        #expect(model.phase == .signedOut)
        #expect(model.lastSignIn == nil)
        #expect(model.notice == nil)
        #expect(model.memberNotFound)
        let body = try #require(backend.requests(to: "/v1/sessions").first?.json)
        #expect(body["createMember"] as? Bool == false, "登入明確要求後台不新建會員")
    }

    @Test("收起詢問:不再送任何請求(使用者回到加入頁再登入一次)")
    func dismissingTheQuestion() async {
        backend.on("POST", "/v1/sessions", .json(404, Replies.error("member_not_found")))
        let model = makeModel()
        await model.restore()
        _ = model.beginAppleAuthorization(linking: false, joining: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")
        #expect(model.memberNotFound)

        model.dismissMemberNotFound()

        #expect(!model.memberNotFound)
        #expect(backend.requests(to: "/v1/sessions").count == 1)
    }

    @Test("加入(joining)照舊:不帶 createMember,後台沒有就新建")
    func joiningCreates() async throws {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "r", memberCreated: true, member: Replies.appleMember)))
        let model = makeModel()
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false, joining: true)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")

        #expect(model.lastSignIn?.memberCreated == true)
        let body = try #require(backend.requests(to: "/v1/sessions").first?.json)
        #expect(body["createMember"] == nil)
    }

    @Test("後台還不支援不新建選項(預設):登入不帶 createMember,維持現行行為,不會先建後擋")
    func unsupportedBackendKeepsCurrentBehavior() async throws {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "r", memberCreated: true, member: Replies.appleMember)))
        let model = makeModel(supportsSignInOnly: false)
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false, joining: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")

        #expect(!model.memberNotFound)
        #expect(model.lastSignIn?.memberCreated == true)
        let body = try #require(backend.requests(to: "/v1/sessions").first?.json)
        #expect(body["createMember"] == nil)
    }

    @Test("登入(不新建)是既有會員:照常進帳號頁")
    func existingMemberSignsIn() async {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "r", memberCreated: false, member: Replies.appleMember)))
        let model = makeModel()
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false, joining: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")

        #expect(!model.memberNotFound)
        #expect(model.lastSignIn?.memberCreated == false)
    }

    @Test("登入時後台自動併進同 email 的既有會員(autoLinked):登入成功並提示,不當成新會員")
    func autoLinkedSignInTellsTheMember() async {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "r", memberCreated: false, autoLinked: true, member: Replies.appleMember)))
        let model = makeModel()
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false, joining: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")

        #expect(model.lastSignIn?.memberCreated == false)
        #expect(model.lastSignIn?.autoLinked == true)
        #expect(model.notice == .autoLinked)
    }

    @Test("一般登入(沒有自動合併):不提示")
    func plainSignInHasNoNotice() async {
        backend.on("POST", "/v1/sessions", .json(200, Replies.session(refreshToken: "r", memberCreated: false, member: Replies.appleMember)))
        let model = makeModel()
        await model.restore()

        _ = model.beginAppleAuthorization(linking: false, joining: false)
        await model.completeAppleAuthorization(idToken: "t", authorizationCode: "c")

        #expect(model.lastSignIn?.autoLinked == false)
        #expect(model.notice == nil)
    }
}
