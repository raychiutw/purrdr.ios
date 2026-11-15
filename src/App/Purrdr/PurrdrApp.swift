import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import SwiftUI

/// 唯一的 composition root:組裝主機通道與畫面 model。
///
/// 真 SSH 還沒做(之後的票),目前唯一的主機是 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機、不連網路;之後加入真主機時，`-uiTesting` 仍要維持這個保證。
@main
struct PurrdrApp: App {
    private let agentList: AgentListModel
    private let claudeUsage: ClaudeUsageModel

    init() {
        let channel: any HostChannel = DemoHost()
        agentList = AgentListModel(client: HerdrClient(channel: channel))
        // Demo 主機不持久化任何東西(行為規格 F21):它的同意只存在記憶體，跟它記憶體裡的家目錄一起重來。
        // 真主機改用 `UserDefaultsHostWriteConsentStore`,移除主機時呼叫 `revokeAll(host:)`。
        claudeUsage = ClaudeUsageModel(host: ClaudeUsageHost(channel: channel), hostID: "demo",
                                       consent: InMemoryHostWriteConsentStore())
    }

    var body: some Scene {
        WindowGroup {
            AgentListView(model: agentList) {
                ClaudeUsageFooter(model: claudeUsage)
            }
        }
    }
}
