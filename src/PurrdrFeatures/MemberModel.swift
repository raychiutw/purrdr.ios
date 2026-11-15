import CryptoKit
import Foundation
import Observation
import PurrdrCore

/// 會員畫面(登入、登入方式、刪除會員)的 model。
@MainActor
@Observable
public final class MemberModel {
    public enum Phase: Equatable {
        /// 還沒確認(啟動時讀取中)。
        case unknown
        case signedOut
        case signedIn(Member)
    }

    public private(set) var phase: Phase = .unknown
    /// 正在跟 Apple／Google／後台溝通;畫面據此停用按鈕、顯示進度。
    public private(set) var isWorking = false
    /// 要提示使用者的事(錯誤或完成通知)。畫面顯示後設回 `nil`。
    public var notice: MemberNotice?

    private let session: MemberSession
    private let google: GoogleSignIn
    private var pendingApple: (nonce: String, linking: Bool)?

    public init(session: MemberSession, google: GoogleSignIn) {
        self.session = session
        self.google = google
    }

    /// 啟動時讀取登入狀態;沒有登入過時不連後台。連不上時維持 `.unknown` 並提示。
    public func restore() async {
        await run {
            if let member = try await session.currentMember() {
                phase = .signedIn(member)
            } else {
                phase = .signedOut
            }
        }
    }

    /// Sign in with Apple 開始前呼叫：產生 nonce,回傳要交給 Apple 的 SHA-256(hex)。
    public func beginAppleAuthorization(linking: Bool) -> String {
        let nonce = GoogleSignIn.randomString()
        pendingApple = (nonce, linking)
        return SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Sign in with Apple 成功後，把 Apple 給的 ID token 與 authorization code 交給後台。
    public func completeAppleAuthorization(idToken: String, authorizationCode: String) async {
        guard let pending = pendingApple else { return }
        pendingApple = nil
        let credential = SignInCredential(method: .apple, idToken: idToken, nonce: pending.nonce, authorizationCode: authorizationCode)
        await submit(credential, linking: pending.linking)
    }

    /// Sign in with Apple 失敗或取消。取消不提示。
    public func appleAuthorizationFailed(canceled: Bool) {
        pendingApple = nil
        if !canceled {
            notice = .failed(String(localized: "Sign in with Apple didn’t finish. Try again."))
        }
    }

    /// 用 Google 登入;`browser` 由畫面以系統瀏覽器提供。
    public func signInWithGoogle(browser: GoogleSignIn.Browser) async {
        await googleCredential(browser: browser, linking: false)
    }

    /// 連結 Google 登入。
    public func linkGoogle(browser: GoogleSignIn.Browser) async {
        await googleCredential(browser: browser, linking: true)
    }

    /// 解除連結;後台要求至少保留一種登入方式。
    public func unlink(_ method: SignInMethod) async {
        await run {
            phase = .signedIn(try await session.unlink(method))
        }
    }

    /// 刪除會員。完成後回到未登入，並提醒 Apple 訂閱要自行取消。
    public func deleteMember() async {
        await run {
            try await session.deleteMember()
            phase = .signedOut
            notice = .deleted
        }
    }

    public func signOut() async {
        await run {
            try await session.signOut()
            phase = .signedOut
        }
    }

    // MARK: -

    private func googleCredential(browser: GoogleSignIn.Browser, linking: Bool) async {
        isWorking = true
        defer { isWorking = false }
        let credential: SignInCredential
        do {
            credential = try await google.credential(browser: browser)
        } catch GoogleSignInError.canceled {
            return
        } catch is CancellationError {
            return
        } catch {
            notice = .failed(String(localized: "Google sign-in didn’t finish. Try again."))
            return
        }
        await submit(credential, linking: linking)
    }

    private func submit(_ credential: SignInCredential, linking: Bool) async {
        await run {
            if linking {
                let result = try await session.link(credential)
                phase = .signedIn(result.member)
                if result.mergedMemberID != nil { notice = .merged }
            } else {
                phase = .signedIn(try await session.signIn(credential).member)
            }
        }
    }

    /// 執行一個會員操作，把錯誤轉成提示。
    private func run(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch BackendError.signedOut {
            phase = .signedOut
            notice = .signedOut
        } catch let BackendError.backend(_, code, message) {
            notice = MemberNotice(code: code, message: message)
        } catch BackendError.unreachable {
            notice = .failed(String(localized: "Couldn’t reach Purrdr. Check your connection and try again."))
        } catch {
            notice = .failed(String(localized: "Something went wrong. Try again."))
        }
    }
}

/// 會員畫面要提示的事。
public enum MemberNotice: Equatable {
    /// 一般錯誤，附給人看的說明。
    case failed(String)
    /// 要連結的登入方式屬於另一個有訂閱或同步資料的會員。
    case identityInUse
    /// 已經有同一種登入方式。
    case methodAlreadyLinked
    /// 連結時併入了另一個空的會員。
    case merged
    /// 會員已刪除;提醒 Apple 訂閱要自行取消。
    case deleted
    /// 登入已失效，要重新登入。
    case signedOut

    init(code: String, message: String) {
        switch code {
        case "identity_in_use": self = .identityInUse
        case "provider_already_linked": self = .methodAlreadyLinked
        case "last_identity": self = .failed(String(localized: "Keep at least one sign-in method."))
        case "apple_revoke_failed": self = .failed(String(localized: "Couldn’t reach Apple to finish deleting. Nothing was deleted. Try again later."))
        case "invalid_id_token": self = .failed(String(localized: "The sign-in didn’t go through. Try again."))
        default: self = .failed(message.isEmpty ? String(localized: "Something went wrong. Try again.") : message)
        }
    }
}
