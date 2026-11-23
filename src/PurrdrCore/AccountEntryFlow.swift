/// 加入流程標在右上的「n / m」。
public struct AccountStepIndicator: Equatable, Sendable {
    public var current: Int
    public var total: Int

    public init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }
}

/// 沒登入時的帳號頁流程(#408、規格 #402):先選「登入」或「加入會員」。
///
/// - 登入:Apple／Google → 直接進帳號頁。
/// - 加入:Apple／Google 註冊 → `AccountJoinFlow`(開通 Plus、開啟通知、同步主機;可略過 Plus) → 完成。
///
/// 後台沒有「登入」與「註冊」的區別(同一個 `POST /v1/sessions`,以 `memberCreated` 回報有沒有新建會員),
/// 所以分流在這裡依結果決定:登入卻新建了會員 → 接著走加入流程;加入卻是既有會員 → 直接登入、進帳號頁。
public struct AccountEntryFlow: Equatable, Sendable {
    public enum Screen: Equatable, Sendable {
        /// 選「登入」或「加入會員」。
        case choose
        case signIn
        /// 加入流程(`join` 是目前步驟)。
        case join
        /// 離開流程:顯示帳號頁。
        case account
    }

    public enum LeadingAction: Equatable, Sendable {
        case back
        case close
    }

    public enum Title: Equatable, Sendable {
        case account
        case signIn
        case join
    }

    /// 登入按鈕的說法:登入頁是「使用 Apple 登入」,加入頁是「使用 Apple 註冊」。
    public enum SignInCopy: Equatable, Sendable {
        case signIn
        case signUp
    }

    public private(set) var screen: Screen = .choose
    public private(set) var join = AccountJoinFlow()
    /// 在加入頁登入時,那個 email 已經是會員(直接登入了那個會員):帳號頁可提示一句。
    public private(set) var joinedExistingMember = false

    public init() {}

    public var leadingAction: LeadingAction {
        switch screen {
        case .choose, .account: .close
        case .signIn: .back
        case .join: join.leadingAction == .back ? .back : .close
        }
    }

    public var title: Title {
        switch screen {
        case .choose, .account: .account
        case .signIn: .signIn
        case .join: .join
        }
    }

    public var signInCopy: SignInCopy {
        screen == .join ? .signUp : .signIn
    }

    /// 加入流程的「n / m」;完成頁與其他畫面沒有。
    public var stepIndicator: AccountStepIndicator? {
        guard screen == .join, join.step != .finished else { return nil }
        // 設計稿(第 26 組)略過 Plus 時也標「3 / 4」。
        let steps: [AccountJoinFlow.Step] = [.createMember, .activatePlus, .turnOnNotifications, .syncHosts]
        guard let index = steps.firstIndex(of: join.step) else { return nil }
        return AccountStepIndicator(current: index + 1, total: steps.count)
    }

    // MARK: - 選擇與切換

    public mutating func chooseSignIn() {
        guard screen == .choose else { return }
        screen = .signIn
    }

    public mutating func chooseJoin() {
        guard screen == .choose else { return }
        screen = .join
    }

    public mutating func switchToJoin() {
        guard screen == .signIn else { return }
        screen = .join
    }

    public mutating func switchToSignIn() {
        guard screen == .join, join.step == .createMember else { return }
        screen = .signIn
    }

    /// 左上的返回(只有登入頁與加入的第 1 步有):回到選擇頁。
    public mutating func back() {
        switch screen {
        case .signIn: screen = .choose
        case .join where join.step == .createMember: screen = .choose
        default: break
        }
    }

    // MARK: - 登入結果

    /// 登入或註冊成功。`memberCreated` 是後台回報這次是否新建了會員。
    public mutating func signedIn(memberCreated: Bool) {
        switch screen {
        case .signIn:
            if memberCreated {
                // 沒有這個會員卻按了登入:會員已建立,接著走加入流程。
                screen = .join
                join.advance()
            } else {
                screen = .account
            }
        case .join where join.step == .createMember:
            if memberCreated {
                join.advance()
            } else {
                joinedExistingMember = true
                screen = .account
            }
        default:
            break
        }
    }

    // MARK: - 加入流程

    public mutating func skipPlus() {
        guard screen == .join else { return }
        join.skipPlus()
    }

    public mutating func plusActivated() {
        guard screen == .join else { return }
        join.plusActivated()
    }

    public mutating func advance() {
        guard screen == .join else { return }
        join.advance()
    }

    /// 完成頁的「開始使用」:離開流程,顯示帳號頁。
    public mutating func finish() {
        guard screen == .join, join.step == .finished else { return }
        screen = .account
    }

    /// 登出或換會員:從頭開始。
    public mutating func reset() {
        self = AccountEntryFlow()
    }
}
