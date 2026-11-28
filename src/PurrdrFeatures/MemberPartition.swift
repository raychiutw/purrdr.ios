import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 目前登入的會員 ID(#405、spec #402):通知與主機同步的本機狀態依它分區存放。
///
/// 沒有會員(未登入、還在讀取登入狀態)時分區是 `nil`:讀到空的、寫入不留下,
/// 所以新會員一定從「未開啟」開始,不會沿用上一位的狀態。
@MainActor
public final class MemberPartition {
    public private(set) var memberID: String?

    public init(memberID: String? = nil) {
        self.memberID = memberID
    }

    /// 換成這個會員的分區(`nil` 是沒有會員)。
    public func activate(_ memberID: String?) {
        self.memberID = memberID
    }

    /// 這個分區在 `UserDefaults` 的 key;沒有會員時是 `nil`。
    func key(_ base: String) -> String? {
        memberID.map { "\(base).\($0)" }
    }

    /// 測試與 UI 測試的記憶體實作預設用:固定一個會員,不必先登入。
    public static func fixed() -> MemberPartition { MemberPartition(memberID: "in-memory") }
}

/// 會員登入狀態與本機分區之間的協調(#405):
/// - 登入、啟動時讀到會員 → 啟用那個會員的分區,通知與同步 model 重讀;
/// - 登出、刪除會員、換會員前 → `leave()` 先撤銷這支裝置在主機與後台的推播配對、停止同步,再清除該會員分區;
/// - 登入已失效(後台撤銷了工作階段)或冷啟動時已登出 → 沒有權杖可撤銷,只清除本機分區。
@MainActor
public final class MemberLocalState {
    public let partition: MemberPartition
    private let session: MemberSession
    private var push: PushService?
    private var hostSync: HostSyncModel?
    private var pushModels: () -> [PushModel] = { [] }

    public init(partition: MemberPartition, session: MemberSession) {
        self.partition = partition
        self.session = session
    }

    /// 接上要跟著分區重讀與清除的通知與同步(它們在 composition root 比會員 model 晚建立)。
    public func attach(push: PushService?, hostSync: HostSyncModel?, pushModels: @escaping () -> [PushModel]) {
        self.push = push
        self.hostSync = hostSync
        self.pushModels = pushModels
    }

    /// 啟用這個會員的分區(`nil` 是登出)。換了會員時上一位的分區不留(沒有權杖可撤銷了,配對由後台依會員處理)。
    public func activate(_ member: Member?) {
        let previous = partition.memberID
        guard previous != member?.id else { return }
        if let previous { removeStoredState(of: previous) }
        partition.activate(member?.id)
        reload()
        if member != nil {
            // 啟動時分區還是空的;讀到會員後,這個會員的配對才補註冊、對帳。
            Task { [push] in await push?.refreshAtLaunch() }
        }
    }

    /// 合併後留下的是另一個會員(#410):這支裝置的通知與同步紀錄搬到新會員的分區(後台的配對、同步資料已歸新會員),
    /// 不重新註冊也不清除,通知與同步維持開啟。留下的就是目前的會員時什麼都不做。
    public func migrate(to member: Member) {
        guard let previous = partition.memberID, previous != member.id else { return }
        push?.store.movePartition(from: previous, to: member.id)
        hostSync?.moveLocalState(from: previous, to: member.id)
        partition.activate(member.id)
        reload()
    }

    /// 登出、刪除會員或換會員之前呼叫:撤銷這支裝置的推播配對、停止同步並清除目前會員的分區。
    /// 撤銷後台配對時連不上就不清除、回 `false`(呼叫端要先提示使用者,否則配對還有效、對方的通知照收)。
    /// `force` 為 `true`(使用者選了「仍要登出」,#420)時連不上也照樣清除本機的配對紀錄、回 `true`;
    /// 後台配對留待之後撤銷,或由「登入中的裝置」頁關閉。
    public func leave(force: Bool = false) async -> Bool {
        guard let memberID = partition.memberID else { return true }
        // 先確認後台連得上,再動任何本機狀態:連不上就什麼都沒改(使用者選取消時仍是完整登入、同步與通知照舊)。
        // `force` 與登入已失效時不用等後台。
        if !force, needsBackendRevocation() {
            do {
                _ = try await session.currentMember()
            } catch BackendError.signedOut {
                // 登入已失效:沒有權杖可撤銷,照下面的流程清除。
            } catch {
                return false
            }
        }
        hostSync?.stop()
        // 經推播外掛移除主機上的配對並撤銷後台配對;主機連不上的留給下面直接撤銷後台。
        for model in pushModels() where model.state == .on {
            await model.turnOff()
        }
        if let push {
            for (host, keyHash) in push.store.pairings.sorted(by: { $0.key < $1.key }) {
                do {
                    try await session.revokePushPairing(keyHash: keyHash)
                } catch BackendError.signedOut {
                    // 登入已失效:後台那邊的配對由會員的工作階段一起處理,這裡沒有權杖可撤銷。
                } catch {
                    if !force { return false }
                    push.pendingRevocations.add(keyHash)
                }
                push.store.setKeyHash(nil, forHost: host)
            }
        }
        removeStoredState(of: memberID)
        reload()
        return true
    }

    /// 有後台配對要撤銷(紀錄裡有,或主機的通知開著)。
    private func needsBackendRevocation() -> Bool {
        if let push, !push.store.pairings.isEmpty { return true }
        return pushModels().contains { $0.state == .on }
    }

    /// 登入已失效或冷啟動時沒有會員:清掉所有會員的本機分區。
    public func discardAll() {
        push?.store.removeAllPartitions()
        hostSync?.removeAllLocalState()
        partition.activate(nil)
        reload()
    }

    /// 0.5x 以前的通知與主機同步狀態存在全 app 共用的 key,沒有綁會員:升級時一律清除,登入後依會員分區重新整理。
    public static func removeLegacyGlobalState(from defaults: UserDefaults = .standard) {
        for key in [
            UserDefaultsPushPairingStore.pairingsKey, UserDefaultsPushPairingStore.registeredTokensKey,
            UserDefaultsPushPairingStore.kindsKey, UserDefaultsHostSyncStore.enabledKey, UserDefaultsHostSyncStore.journalKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    private func removeStoredState(of memberID: String) {
        push?.store.removePartition(of: memberID)
        hostSync?.removeLocalState(of: memberID)
    }

    private func reload() {
        push?.reloadModels()
        hostSync?.reload()
    }
}
