import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機的「狀態」頁(spec #281):HTTPS 主機的主機服務與已配對裝置，各區塊自己載入。
struct HostStatusView: View {
    let connection: any HostConnection
    @State private var hostService: HostServiceStatusModel?

    init(connection: any HostConnection) {
        self.connection = connection
        if let managing = connection as? any HostConnection & HostServiceManaging {
            _hostService = State(initialValue: HostServiceStatusModel(connection: managing))
        }
    }

    var body: some View {
        List {
            if let hostService {
                HostServiceSection(model: hostService)
            }
            // 已配對裝置(#291)
        }
        .refreshable { await hostService?.refresh() }
        .accessibilityIdentifier("hostStatus")
        .navigationTitle("Status")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
