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

    /// 一次登入(不含連結另一種登入方式)的結果(#408):登入與加入分流依 `memberCreated` 決定下一頁。
    /// 每次登入的 `id` 都不同,畫面用 `onChange` 就收得到每一次。
    public struct SignInEvent: Equatable, Sendable {
        public var id: Int
        /// 後台回報這次登入新建了會員。
        public var memberCreated: Bool
        /// 後台把這個登入方式自動歸進 email 相同的既有會員。
        public var autoLinked: Bool = false
    }

    public private(set) var lastSignIn: SignInEvent?
    /// 登入頁查無這個帳號的會員(#434):畫面問「找不到這個帳號的會員,要加入嗎?」。
    public private(set) var memberNotFound = false

    /// 收起「查無會員」的詢問(選了加入或取消都呼叫;加入由畫面切到加入頁,使用者再登入一次)。
    public func dismissMemberNotFound() { memberNotFound = false }
    private var signInCount = 0

    /// 新增登入方式時發現它已屬於另一個會員(#410):等使用者看過兩邊摘要、確認後才合併。
    /// 摘要只會在新增登入方式「已確認過裝置擁有者」之後出現,合併沿用那次確認、不再問第二次(#455)。
    public struct MergeProposal: Equatable, Sendable {
        public var summary: MemberMergeSummary
        /// 剛驗證的憑證;確認合併時重新帶給後台。
        var credential: SignInCredential
    }

    public private(set) var pendingMerge: MergeProposal?

    /// 目前這次操作是否以「暫時連不上」收尾(讀到本機快照就算成功,但後台沒答)。
    private var endedLimited = false
    private let session: MemberSession
    private let google: GoogleSignIn
    private var pendingApple: (nonce: String, linking: Bool, joining: Bool)?
    /// 通知與主機同步的本機狀態依會員分區(#405);`nil` 時不管本機狀態(只有測試)。
    private let localState: MemberLocalState?
    /// 新增、移除登入方式與合併前,要求裝置擁有者驗證(Face ID／Touch ID／密碼);`nil` 時不驗證(只有測試)。
    private let confirmOwner: (@MainActor @Sendable () async -> Bool)?

    /// 登入中的裝置(#409):帳號頁列出並撤銷其他裝置。
    public let signInDevices: SignInDevicesModel

    /// - Parameter confirmOwner: 撤銷其他裝置、新增與移除登入方式、合併等會改動帳號的操作前,要求裝置擁有者驗證;`nil` 時不驗證(只有測試)。
    public init(
        session: MemberSession, google: GoogleSignIn, localState: MemberLocalState? = nil,
        confirmOwner: (@MainActor @Sendable () async -> Bool)? = nil
    ) {
        self.session = session
        self.google = google
        self.localState = localState
        self.confirmOwner = confirmOwner
        signInDevices = SignInDevicesModel(session: session, confirmOwner: confirmOwner)
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
    /// `joining` 為 `false`(登入頁)時不新建會員:查無會員改問要不要加入(`memberNotFound`,#434)。
    public func beginAppleAuthorization(linking: Bool, joining: Bool = true) -> String {
        let nonce = GoogleSignIn.randomString()
        pendingApple = (nonce, linking, joining)
        return SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Sign in with Apple 成功後，把 Apple 給的 ID token 與 authorization code 交給後台。
    public func completeAppleAuthorization(idToken: String, authorizationCode: String) async {
        guard let pending = pendingApple else { return }
        pendingApple = nil
        let credential = SignInCredential(method: .apple, idToken: idToken, nonce: pending.nonce, authorizationCode: authorizationCode)
        await submit(credential, linking: pending.linking, joining: pending.joining)
    }

    /// Sign in with Apple 失敗或取消。取消不提示。
    public func appleAuthorizationFailed(canceled: Bool) {
        pendingApple = nil
        if !canceled {
            notice = .failed(String(localized: "Sign in with Apple didn’t finish. Try again."))
        }
    }

    /// 直接以憑證登入(測試替身與 UI 測試用,正式畫面走 Apple／Google 按鈕)。
    public func signIn(with credential: SignInCredential, joining: Bool = true) async {
        await submit(credential, linking: false, joining: joining)
    }

    /// 直接以憑證連結另一種登入方式(測試替身與 UI 測試用)。
    public func link(with credential: SignInCredential) async {
        await submit(credential, linking: true)
    }

    /// 用 Google 登入;`browser` 由畫面以系統瀏覽器提供。
    public func signInWithGoogle(browser: GoogleSignIn.Browser, joining: Bool = true) async {
        await googleCredential(browser: browser, linking: false, joining: joining)
    }

    /// 連結 Google 登入。
    public func linkGoogle(browser: GoogleSignIn.Browser) async {
        await googleCredential(browser: browser, linking: true)
    }

    /// 目前的會員還有不只一種登入方式,才能移除其中一種(至少保留一種)。
    public var canUnlink: Bool {
        if case .signedIn(let member) = phase { return member.identities.count > 1 }
        return false
    }

    /// 移除一種登入方式;先確認裝置擁有者(#410)。至少保留一種:只剩一種時不問、不送,提示原因。
    public func unlink(_ method: SignInMethod) async {
        // 只擋「移除唯一一種」;沒連結的方式交給後台回 identity_not_linked。
        if case .signedIn(let member) = phase, member.identities.count <= 1, member.identity(method) != nil {
            notice = .failed(String(localized: "Keep at least one sign-in method."))
            return
        }
        await run {
            guard await ownerConfirmed() else { return }
            let member = try await session.unlink(method)
            phase = .signedIn(member)
            localState?.activate(member)
        }
    }

    /// 確認合併(#410):兩邊都有有效訂閱時不能合併;沿用新增登入方式時的身分確認(#455)。
    /// 留下的可能是對方會員:本機的通知與同步紀錄搬到它的分區,通知與同步維持開啟。
    public func confirmMerge() async {
        guard let proposal = pendingMerge, proposal.summary.canMerge else { return }
        await run {
            let result = try await session.merge(proposal.credential)
            pendingMerge = nil
            phase = .signedIn(result.member)
            localState?.migrate(to: result.member)
            localState?.activate(result.member)
            notice = .merged
        }
    }

    /// 取消合併:收起摘要,什麼都不送。
    public func cancelMerge() {
        pendingMerge = nil
    }

    /// 刪除會員。完成後回到未登入，並提醒 Apple 訂閱要自行取消。
    /// 先撤銷這支裝置的推播配對並清除本機分區(#405);撤銷不了(連不上後台)時照樣刪除:後台刪除會員會一併刪掉它的配對。
    /// 刪除前要先確認裝置擁有者(#412);確認沒過什麼都不做。
    public func deleteMember() async {
        await run {
            guard await ownerConfirmed() else { return }
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
    /// 先確認裝置擁有者(#412);`force` 是同一次登出流程的第二步(已確認過),不再問。
    public func signOut(force: Bool = false) async {
        await run {
            if !force, !(await ownerConfirmed()) { return }
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

    private func googleCredential(browser: GoogleSignIn.Browser, linking: Bool, joining: Bool = true) async {
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
        await submit(credential, linking: linking, joining: joining)
    }

    private func submit(_ credential: SignInCredential, linking: Bool, joining: Bool = true) async {
        await run {
            if linking {
                guard await ownerConfirmed() else { return }
                do {
                    let result = try await session.link(credential)
                    phase = .signedIn(result.member)
                    localState?.activate(result.member)
                } catch BackendError.mergeRequired(let summary) {
                    // 不是錯誤:這個登入方式已是另一個會員,先讓使用者看兩邊摘要再決定。
                    pendingMerge = MergeProposal(summary: summary, credential: credential)
                }
            } else {
                // 已登入時再登入:換會員前先撤銷上一位的推播配對(登入後就沒有他的權杖了)。
                if case .signedIn = phase, !(await leaveLocalState()) { return }
                let result = try await session.signIn(credential, createIfMissing: joining)
                phase = .signedIn(result.member)
                localState?.activate(result.member)
                signInCount += 1
                lastSignIn = SignInEvent(id: signInCount, memberCreated: result.memberCreated, autoLinked: result.autoLinked)
                if result.autoLinked { notice = .autoLinked }
            }
        }
    }

    /// 會改動帳號的操作先確認是裝置擁有者本人(`confirmOwner` 為 `nil` 時視為通過,只有測試)。
    private func ownerConfirmed() async -> Bool {
        guard let confirmOwner else { return true }
        return await confirmOwner()
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
        } catch BackendError.subscriptionInUse {
            notice = .subscriptionInUse
        } catch BackendError.mergeRequired {
            // 只有連結會處理;其他操作不會收到,收到就當一般錯誤。
            notice = .failed(String(localized: "Something went wrong. Try again."))
        } catch let BackendError.backend(status, code, _) where status == 404 && code == "member_not_found" {
            // 登入頁查無會員(後台不新建):不是錯誤,問使用者要不要加入(#434)。
            memberNotFound = true
        } catch let BackendError.backend(status, code, message) {
            // 合併被後台擋下:摘要已過時,收起。
            if code == BackendErrorCode.subscriptionConflict || code == BackendErrorCode.providerAlreadyLinked
                || code == "no_merge_needed" { pendingMerge = nil }
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
    /// 合併時兩邊都有有效訂閱(一個會員只能有一個):要先讓其中一邊不再有效。
    case subscriptionConflict
    /// 這個商店訂閱已屬於另一個會員。
    case subscriptionInUse
    /// 已經有同一種登入方式。
    case methodAlreadyLinked
    /// 兩個會員已合併成一個。
    case merged
    /// 登入時後台發現 email 與既有會員相同,自動歸到那個會員(不是新會員)。
    case autoLinked
    /// 會員已刪除;提醒 Apple 訂閱要自行取消。
    case deleted
    /// 登入已失效，要重新登入。
    case signedOut
    /// 登出時連不上後台、撤銷不了這支裝置的通知配對:提示並提供「仍要登出」(#420)。
    case signOutBackendUnreachable

    init(code: String, message: String) {
        switch code {
        case BackendErrorCode.subscriptionConflict: self = .subscriptionConflict
        case BackendErrorCode.subscriptionInUse: self = .subscriptionInUse
        case BackendErrorCode.providerAlreadyLinked: self = .methodAlreadyLinked
        case "no_merge_needed": self = .failed(String(localized: "That sign-in method is already part of this member."))
        case "last_identity": self = .failed(String(localized: "Keep at least one sign-in method."))
        case "apple_revoke_failed": self = .failed(String(localized: "Couldn’t reach Apple to finish deleting. Nothing was deleted. Try again later."))
        case "invalid_id_token": self = .failed(String(localized: "The sign-in didn’t go through. Try again."))
        default: self = .failed(message.isEmpty ? String(localized: "Something went wrong. Try again.") : message)
        }
    }
}
