import Foundation

/// 會員(GLOSSARY):以 Sign in with Apple 或 Google 登入 Purrdr 後台的使用者身分。
public struct Member: Equatable, Sendable {
    public var id: String
    /// 已連結的登入方式，每種最多一個。
    public var identities: [MemberIdentity]

    public init(id: String, identities: [MemberIdentity]) {
        self.id = id
        self.identities = identities
    }

    public func identity(_ method: SignInMethod) -> MemberIdentity? {
        identities.first { $0.method == method }
    }

    /// 帳號頁顯示的名稱(#246):第一個有 email 的登入方式。
    public var accountName: String? {
        identities.lazy
            .compactMap { $0.email?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// 帳號鈕的頭像字(#246);`nil` 時畫面用人像符號。
    public var avatarInitial: String? {
        accountName?.first.map { String($0).uppercased() }
    }
}

/// 會員連結的一種登入方式。
public struct MemberIdentity: Equatable, Sendable {
    public var method: SignInMethod
    /// 登入時的 email;Sign in with Apple 可能是轉寄地址，也可能沒有。
    public var email: String?
    public var linkedAt: Date

    public init(method: SignInMethod, email: String?, linkedAt: Date) {
        self.method = method
        self.email = email
        self.linkedAt = linkedAt
    }
}

/// 登入方式。iOS 有兩種，Android 只有 Google(ADR-0007)。
public enum SignInMethod: String, CaseIterable, Sendable {
    case apple
    case google
}

/// 向 Apple 或 Google 取得、要交給後台驗證的登入憑證。
public struct SignInCredential: Sendable, Equatable {
    public var method: SignInMethod
    public var idToken: String
    /// app 產生的 nonce 原文(後台依登入方式比對 ID token 的 nonce)。
    public var nonce: String
    /// Sign in with Apple 才有：後台拿去換 refresh token,刪除會員時撤銷。
    public var authorizationCode: String?

    public init(method: SignInMethod, idToken: String, nonce: String, authorizationCode: String? = nil) {
        self.method = method
        self.idToken = idToken
        self.nonce = nonce
        self.authorizationCode = authorizationCode
    }
}
