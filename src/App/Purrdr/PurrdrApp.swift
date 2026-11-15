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
    private let workspaceActions: WorkspaceActionsModel

    init() {
        let channel: any HostChannel = DemoHost()
        let client = HerdrClient(channel: channel)
        let agentList = AgentListModel(client: client)
        // UI 測試每次啟動都從空白的釘選、靜音開始，不讀寫這台模擬器的 UserDefaults。
        let preferences: any ChatPreferencesStore = ProcessInfo.processInfo.arguments.contains("-uiTesting")
            ? InMemoryChatPreferencesStore() : UserDefaultsChatPreferencesStore()
        self.agentList = agentList
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
    }

    var body: some Scene {
        WindowGroup {
            // 版面圖選了 Pane 之後要開的聊天／終端機畫面還沒有(#12、Pane 終端機那張票接上 onOpen)。
            AgentListView(model: agentList, actions: workspaceActions)
        }
    }
}
