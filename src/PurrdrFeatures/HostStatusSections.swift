import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機編輯頁下方的主機狀態區塊(spec #281):HTTPS 主機的主機服務(#290)與已配對裝置(#291),各區塊自己載入。
struct HostStatusSections: View {
    @State private var hostService: HostServiceStatusModel?
    private let pairedDevices: (any PairedDevicesManaging)?

    init(connection: any HostConnection) {
        if let managing = connection as? any HostConnection & HostServiceManaging {
            _hostService = State(initialValue: HostServiceStatusModel(connection: managing))
        }
        pairedDevices = connection as? any PairedDevicesManaging
    }

    var body: some View {
        if let hostService {
            HostServiceSection(model: hostService)
        }
        if let pairedDevices {
            PairedDevicesSection(host: pairedDevices)
        }
    }
}
