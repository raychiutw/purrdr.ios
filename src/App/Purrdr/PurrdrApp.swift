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
    private let navigation = TopNavigationModel()
    private let client: HerdrClient
    private let transcripts: TranscriptReader
    /// 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
    private let conversationCache = InMemoryConversationCache()

    init() {
        let channel: any HostChannel = DemoHost()
        let client = HerdrClient(channel: channel)
        let transcripts = TranscriptReader(channel: channel)
        let agentList = AgentListModel(client: client, transcripts: transcripts)
        // UI 測試每次啟動都從空白的釘選、靜音開始，不讀寫這台模擬器的 UserDefaults。
        let preferences: any ChatPreferencesStore = ProcessInfo.processInfo.arguments.contains("-uiTesting")
            ? InMemoryChatPreferencesStore() : UserDefaultsChatPreferencesStore()
        self.client = client
        self.transcripts = transcripts
        self.agentList = agentList
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
    }

    var body: some Scene {
        WindowGroup {
            TopNavigationView(navigation: navigation, agentList: agentList, workspaceActions: workspaceActions) { paneID, sessionID in
                ConversationModel(
                    client: client, transcripts: transcripts, paneID: paneID, knownSessionID: sessionID, cache: conversationCache
                )
            }
        }
    }
}
