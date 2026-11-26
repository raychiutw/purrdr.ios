import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機 tab 總頁的主機服務(#290)與已配對裝置(#291)model(spec #281;只有已配對的 HTTPS 主機)。
@MainActor
final class HostStatusModels {
    let hostService: HostServiceStatusModel?
    let pairedDevices: PairedDevicesModel?

    /// - Parameter removeHost: 已配對裝置「這支裝置」那列開移除主機的確認。
    init(connection: any HostConnection, hostName: String = "", removeHost: (@MainActor () -> Void)?) {
        hostService = (connection as? any HostConnection & HostServiceManaging).map { HostServiceStatusModel(connection: $0) }
        pairedDevices = (connection as? any PairedDevicesManaging).map { PairedDevicesModel(host: $0, hostName: hostName, removeHost: removeHost) }
    }

    /// 下拉重新整理:兩個都重讀。
    func refresh() async {
        await hostService?.refresh()
        await pairedDevices?.load()
    }
}
