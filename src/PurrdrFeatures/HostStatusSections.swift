import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機頁下方主機狀態區塊的 model(spec #281):HTTPS 主機的主機服務(#290)與已配對裝置(#291)。
@MainActor
final class HostStatusModels {
    let hostService: HostServiceStatusModel?
    let pairedDevices: PairedDevicesModel?

    /// - Parameter removeHost: 已配對裝置「這支裝置」那列開移除主機的確認。
    init(connection: any HostConnection, removeHost: (@MainActor () -> Void)?) {
        hostService = (connection as? any HostConnection & HostServiceManaging).map { HostServiceStatusModel(connection: $0) }
        pairedDevices = (connection as? any PairedDevicesManaging).map { PairedDevicesModel(host: $0, removeHost: removeHost) }
    }

    /// 下拉重新整理：兩個區塊都重讀。
    func refresh() async {
        await hostService?.refresh()
        await pairedDevices?.load()
    }
}

/// 主機編輯頁下方的主機狀態區塊：主機服務出現時自己載入，已配對裝置由 `PairedDevicesDialogs` 載入;下拉重新整理由編輯頁的 `Form` 呼叫 `HostStatusModels.refresh()`。
struct HostStatusSections: View {
    let models: HostStatusModels

    var body: some View {
        if let hostService = models.hostService {
            HostServiceSection(model: hostService)
        }
        if let pairedDevices = models.pairedDevices {
            PairedDevicesSection(model: pairedDevices)
        }
    }
}

extension View {
    /// `action` 是 `nil` 時不能下拉重新整理。
    @ViewBuilder
    func refreshable(_ action: (@Sendable () async -> Void)?) -> some View {
        if let action {
            refreshable(action: action)
        } else {
            self
        }
    }
}
