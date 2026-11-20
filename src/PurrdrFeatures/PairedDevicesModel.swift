import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 主機狀態頁「已配對裝置」區塊的 model(#291):列出連線配對的裝置，撤銷別支裝置前先確認。
///
/// 唯讀裝置只能看;這支裝置不在這裡撤銷(移除主機時會撤銷自己的權杖)。
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

    public init(host: any PairedDevicesManaging) {
        self.host = host
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

    /// 送出撤銷，成功後重新列出。
    public func confirmRevocation() async {
        guard let device = confirmingRevocation else { return }
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
