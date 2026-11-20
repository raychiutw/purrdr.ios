import Foundation
import Observation
import PurrdrCore

/// 帳號頁「通知裝置」(#266):會員名下所有收通知的裝置，可遠端關閉與改名。
///
/// 關閉這支裝置時連本機的配對一起清掉，「通知」區塊的主機回到關閉;清單裡沒有這支裝置(被別支關閉)時也一樣。
@MainActor
@Observable
public final class PushDevicesModel {
    public enum Problem: Equatable {
        /// 需要 Purrdr Plus(改名要有效訂閱;清單與關閉不用，訂閱到期也能關掉遺失的裝置)。
        case needsSubscription
        case failed(String)
    }

    public private(set) var devices: [PushDevice] = []
    /// 讀過一次清單(成功或失敗)。
    public private(set) var hasLoaded = false
    /// 正在關閉或改名的裝置。
    public private(set) var busyDeviceIDs: Set<String> = []
    public var problem: Problem?
    /// 等使用者在對話框確認的動作(畫面狀態，放這裡讓對話框能掛在帳號頁的 List 上)。
    public var pendingAction: PendingAction?

    public enum PendingAction: Equatable {
        case rename(PushDevice)
        case turnOff(PushDevice)
    }

    private let service: PushService

    public init(service: PushService) {
        self.service = service
    }

    /// 重讀清單。讀不到時保留上次的清單並說明。
    public func load() async {
        do {
            let devices = try await service.session.pushDevices(currentDeviceID: service.device().id.backendValue)
            self.devices = devices
            problem = nil
            service.reconcile(with: devices)
        } catch {
            record(error)
            if problem == .needsSubscription { devices = [] }
        }
        hasLoaded = true
    }

    /// 改名;名稱去頭尾空白後要 1～64 字。成功回 `true`。
    @discardableResult
    public func rename(_ device: PushDevice, to text: String) async -> Bool {
        guard let name = PushDeviceIdentity.validName(text) else { return false }
        busyDeviceIDs.insert(device.id)
        defer { busyDeviceIDs.remove(device.id) }
        do {
            let renamed = try await service.session.renamePushDevice(device.id, to: name, currentDeviceID: service.device().id.backendValue)
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = renamed }
            problem = nil
            return true
        } catch {
            record(error)
            return false
        }
    }

    /// 遠端關閉：撤銷那支裝置在所有主機的配對。後台說已沒有配對也當作已關閉。
    public func turnOff(_ device: PushDevice) async {
        busyDeviceIDs.insert(device.id)
        defer { busyDeviceIDs.remove(device.id) }
        do {
            try await service.session.revokePushDevice(device.id)
        } catch BackendError.backend(_, "device_not_found", _) {
            // 已經沒有配對：照樣從清單拿掉。
        } catch {
            record(error)
            return
        }
        devices.removeAll { $0.id == device.id }
        problem = nil
        if device.isCurrent || device.id == (try? service.device())?.id.backendValue { service.forgetAllPairings() }
    }

    private func record(_ error: any Error) {
        switch error {
        case BackendError.backend(_, "subscription_required", _), BackendError.signedOut:
            problem = .needsSubscription
        case BackendError.unreachable:
            problem = .failed(String(localized: "Couldn’t reach Purrdr’s server. Check your connection and try again."))
        default:
            problem = .failed(String(localized: "Couldn’t update notification devices. Try again."))
        }
    }
}
