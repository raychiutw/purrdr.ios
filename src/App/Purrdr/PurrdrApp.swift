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
    private let navigation = TopNavigationModel()
    private let client: HerdrClient
    private let transcripts: TranscriptReader
    /// 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
    private let conversationCache = InMemoryConversationCache()

    init() {
        let channel: any HostChannel = DemoHost()
        client = HerdrClient(channel: channel)
        transcripts = TranscriptReader(channel: channel)
        agentList = AgentListModel(client: client, transcripts: transcripts)
    }

    var body: some Scene {
        WindowGroup {
            TopNavigationView(navigation: navigation, agentList: agentList) { paneID, sessionID in
                ConversationModel(
                    client: client, transcripts: transcripts, paneID: paneID, knownSessionID: sessionID, cache: conversationCache
                )
            }
        }
    }
}
