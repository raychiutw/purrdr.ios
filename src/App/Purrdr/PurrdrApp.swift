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

    init() {
        let channel: any HostChannel = DemoHost()
        agentList = AgentListModel(client: HerdrClient(channel: channel))
    }

    var body: some Scene {
        WindowGroup {
            AgentListView(model: agentList)
        }
    }
}
