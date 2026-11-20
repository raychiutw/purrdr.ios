import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 主機頁(ⓘ)「已配對裝置」區塊的 model(#291):列出連線配對的裝置，撤銷別支裝置前先確認。
///
/// 唯讀裝置只能看;這支裝置不在這裡撤銷，那列導到移除主機(移除時以 POST /v1/revoke 撤銷自己的權杖)。
@MainActor
@Observable
public final class PairedDevicesModel {
    public enum State: Equatable {
        case loading
        case loaded([PairedDeviceRecord])
        case failed(String)
    }

    public private(set) var state: State = .loading
    /// 這支裝置配對成唯讀。
    public private(set) var isReadOnly = false
    /// 等使用者確認要撤銷的裝置。
    public private(set) var confirmingRevocation: PairedDeviceRecord?
    /// 撤銷中的裝置 id。
    public private(set) var revokingID: String?
    /// 上一次撤銷失敗的說明。
    public private(set) var revocationError: String?

    private let host: any PairedDevicesManaging
    private let removeHost: (@MainActor () -> Void)?

    /// - Parameter removeHost: 開移除主機的確認(主機清單的流程);`nil` 時「這支裝置」那列沒有動作。
    public init(host: any PairedDevicesManaging, removeHost: (@MainActor () -> Void)? = nil) {
        self.host = host
        self.removeHost = removeHost
    }

    /// 「這支裝置」那列可以移除主機(唯讀裝置也可以)。
    public func canRemoveHost(from device: PairedDeviceRecord) -> Bool {
        device.isCurrentDevice && removeHost != nil
    }

    public func requestHostRemoval(from device: PairedDeviceRecord) {
        guard canRemoveHost(from: device) else { return }
        removeHost?()
    }

    public func load() async {
        do {
            isReadOnly = try await host.isReadOnlyDevice()
            state = .loaded(try await host.pairedDevices())
        } catch {
            state = .failed(HostErrorText.message(for: error))
        }
    }

    public func canRevoke(_ device: PairedDeviceRecord) -> Bool {
        !isReadOnly && !device.isCurrentDevice && revokingID == nil
    }

    public func requestRevocation(of device: PairedDeviceRecord) {
        guard canRevoke(device) else { return }
        revocationError = nil
        confirmingRevocation = device
    }

    public func cancelRevocation() {
        confirmingRevocation = nil
    }

    /// 確認後送出撤銷，成功後重新列出。以按下確認時的裝置為準：對話框收起時已清掉 `confirmingRevocation`。
    public func confirmRevocation(of device: PairedDeviceRecord) async {
        guard canRevoke(device) else { return }
        confirmingRevocation = nil
        revokingID = device.id
        defer { revokingID = nil }
        do {
            try await host.revokePairedDevice(device.id)
        } catch {
            revocationError = HostErrorText.message(for: error)
            return
        }
        await load()
    }
}
