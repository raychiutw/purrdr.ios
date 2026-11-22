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
    /// 已登入、但這一刻連不上 Purrdr 後台(#406):帳號頁顯示「暫時連不上,你仍是登入狀態」。連得上就消失。
    public private(set) var isConnectionLimited = false
    /// 要提示使用者的事(錯誤或完成通知)。畫面顯示後設回 `nil`。
    public var notice: MemberNotice?

    /// 目前這次操作是否以「暫時連不上」收尾(讀到本機快照就算成功,但後台沒答)。
    private var endedLimited = false
    private let session: MemberSession
    private let google: GoogleSignIn
    private var pendingApple: (nonce: String, linking: Bool)?
    /// 通知與主機同步的本機狀態依會員分區(#405);`nil` 時不管本機狀態(只有測試)。
    private let localState: MemberLocalState?

    public init(session: MemberSession, google: GoogleSignIn, localState: MemberLocalState? = nil) {
        self.session = session
        self.google = google
        self.localState = localState
    }

    /// 啟動時讀取登入狀態;沒有登入過時不連後台。
    /// 連不上或後台暫時出錯時**不登出**(#406):本機有上次讀到的會員就維持登入、標成 `isConnectionLimited`;
    /// 沒有(升級前登入的)就維持 `.unknown` 並提示。只有後台明確拒絕才回到未登入。
    public func restore() async {
        await run {
            let member: Member?
            do {
                member = try await session.currentMember()
            } catch let error where Self.isTemporary(error) {
                guard let cached = try await session.cachedMember() else { throw error }
                phase = .signedIn(cached)
                localState?.activate(cached)
                endedLimited = true
                return
            }
            if let member {
                phase = .signedIn(member)
                localState?.activate(member)
            } else {
                phase = .signedOut
                localState?.discardAll()
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
            let member = try await session.unlink(method)
            phase = .signedIn(member)
            localState?.activate(member)
        }
    }

    /// 刪除會員。完成後回到未登入，並提醒 Apple 訂閱要自行取消。
    /// 先撤銷這支裝置的推播配對並清除本機分區(#405);撤銷不了(連不上後台)時照樣刪除:後台刪除會員會一併刪掉它的配對。
    public func deleteMember() async {
        await run {
            _ = await localState?.leave()
            try await session.deleteMember()
            phase = .signedOut
            localState?.discardAll()
            notice = .deleted
        }
    }

    /// 登出。先撤銷這支裝置的推播配對並停止同步、清除本機分區(#405);
    /// 連不上後台撤銷不了時先不登出,提示 `.signOutBackendUnreachable` 讓使用者選「仍要登出」(`force`,#420):
    /// 此時照樣清本機分區與主機上的配對,後台配對留待之後撤銷。
    public func signOut(force: Bool = false) async {
        await run {
            if force {
                _ = await localState?.leave(force: true)
            } else {
                guard await leaveLocalState(unreachable: .signOutBackendUnreachable) else { return }
            }
            try await session.signOut()
            phase = .signedOut
            localState?.discardAll()
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
                localState?.activate(result.member)
                if result.mergedMemberID != nil { notice = .merged }
            } else {
                // 已登入時再登入:換會員前先撤銷上一位的推播配對(登入後就沒有他的權杖了)。
                if case .signedIn = phase, !(await leaveLocalState()) { return }
                let member = try await session.signIn(credential).member
                phase = .signedIn(member)
                localState?.activate(member)
            }
        }
    }

    /// 撤銷並清除目前會員的本機狀態;撤銷不了時提示並回 `false`。
    private func leaveLocalState(unreachable: MemberNotice? = nil) async -> Bool {
        guard let localState, !(await localState.leave()) else { return true }
        notice = unreachable
            ?? .failed(String(localized: "Couldn’t turn off notifications for this device. Check your connection and try again."))
        return false
    }

    /// 連不上、逾時或後台暫時出錯(5xx):登入仍然有效,稍後再試。
    private static func isTemporary(_ error: any Error) -> Bool {
        switch error as? BackendError {
        case .unreachable: true
        case .backend(let status, _, _): status >= 500
        default: false
        }
    }

    /// 執行一個會員操作，把錯誤轉成提示。
    private func run(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        endedLimited = false
        do {
            try await operation()
            // 後台答得上來:不再是暫時連不上(restore 靠本機快照撐住時例外)。
            isConnectionLimited = endedLimited
        } catch BackendError.signedOut {
            phase = .signedOut
            isConnectionLimited = false
            localState?.discardAll()
            notice = .signedOut
        } catch let BackendError.backend(status, code, message) {
            if status >= 500, case .signedIn = phase { isConnectionLimited = true }
            notice = MemberNotice(code: code, message: message)
        } catch BackendError.unreachable {
            if case .signedIn = phase { isConnectionLimited = true }
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
    /// 登出時連不上後台、撤銷不了這支裝置的通知配對:提示並提供「仍要登出」(#420)。
    case signOutBackendUnreachable

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
