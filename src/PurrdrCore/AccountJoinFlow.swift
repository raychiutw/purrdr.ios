/// 加入會員的步驟流程(#407、規格 #402):建立會員 → 開通 Plus(可略過) → 開啟通知(逐台主機) → 同步主機 → 完成。
///
/// 只有「加入」走這個流程;「登入」直接進帳號頁。
public struct AccountJoinFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case createMember
        case activatePlus
        case turnOnNotifications
        case syncHosts
        case finished
    }

    /// 完成頁的種類:略過 Plus 時寫「會員已建立,之後可在帳號頁開通」。
    public enum Completion: Equatable, Sendable {
        case plusReady
        case memberCreated
    }

    /// 左上的動作:第 2 步起是「關閉」,不回到已完成的建立會員。
    public enum LeadingAction: Equatable, Sendable {
        case back
        case close
    }

    public private(set) var step: Step = .createMember
    public private(set) var skippedPlus = false

    public init() {}

    public var leadingAction: LeadingAction {
        step == .createMember ? .back : .close
    }

    public var completion: Completion? {
        guard step == .finished else { return nil }
        return skippedPlus ? .memberCreated : .plusReady
    }

    /// 進度列上看得到的步驟;略過 Plus 後沒有同步步驟。
    public var visibleSteps: [Step] {
        skippedPlus
            ? [.createMember, .activatePlus, .turnOnNotifications]
            : [.createMember, .activatePlus, .turnOnNotifications, .syncHosts]
    }

    public mutating func advance() {
        switch step {
        case .createMember: step = .activatePlus
        case .activatePlus: step = .turnOnNotifications
        case .turnOnNotifications: step = skippedPlus ? .finished : .syncHosts
        case .syncHosts: step = .finished
        case .finished: break
        }
    }

    /// 在開通 Plus 那一步按「稍後再說」。
    public mutating func skipPlus() {
        guard step == .activatePlus else { return }
        skippedPlus = true
        step = .turnOnNotifications
    }

    /// 略過後又在通知步驟開通了 Plus:同步步驟回來(通知本來就不需要 Plus,#675)。
    public mutating func plusActivated() {
        skippedPlus = false
    }
}
