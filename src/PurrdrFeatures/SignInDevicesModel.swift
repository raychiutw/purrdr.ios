import Foundation
import Observation
import PurrdrCore

/// 帳號頁「登入中的裝置」(#409):這個會員在後台的工作階段(每支裝置一個)。撤銷另一支 = 把它登出,要先確認是本人。
///
/// 跟「通知裝置」分開:那是只關通知、不登出;這裡撤銷後那支裝置要重新登入。
@MainActor
@Observable
public final class SignInDevicesModel {
    /// 還沒讀到清單時是 `nil`(帳號頁不顯示數量)。
    public private(set) var devices: [SignInDevice]?
    public private(set) var busyDeviceIDs: Set<String> = []
    /// 讀取或撤銷失敗的說明;成功後清掉。
    public var problem: String?
    /// 等使用者在對話框確認撤銷的裝置(畫面狀態)。
    public var pendingRevoke: SignInDevice?

    private let session: MemberSession
    private let confirmOwner: (@MainActor @Sendable () async -> Bool)?

    /// - Parameter confirmOwner: 撤銷前要求裝置擁有者驗證;`nil` 時不驗證(只有測試)。
    public init(session: MemberSession, confirmOwner: (@MainActor @Sendable () async -> Bool)? = nil) {
        self.session = session
        self.confirmOwner = confirmOwner
    }

    /// 讀取清單。讀不到時保留上次的清單並說明(不會因此登出)。
    public func load() async {
        do {
            devices = try await session.signInDevices()
            problem = nil
        } catch BackendError.signedOut {
            devices = nil
        } catch {
            problem = String(localized: "Couldn’t load your devices. Try again.")
        }
    }

    /// 撤銷另一支裝置。目前這支不能撤銷;沒通過本人確認就什麼都不做。
    public func revoke(_ device: SignInDevice) async {
        guard !device.isCurrent, !busyDeviceIDs.contains(device.id) else { return }
        if let confirmOwner, !(await confirmOwner()) { return }
        busyDeviceIDs.insert(device.id)
        defer { busyDeviceIDs.remove(device.id) }
        do {
            try await session.revokeSignInDevice(device.id)
            devices?.removeAll { $0.id == device.id }
            problem = nil
        } catch {
            problem = String(localized: "Couldn’t sign out that device. Try again.")
        }
    }
}
