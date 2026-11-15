import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import SwiftUI

/// 唯一的 composition root:組裝主機通道、Purrdr 後台與畫面 model。
///
/// 真 SSH 還沒做(之後的票),目前唯一的主機是 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機、不連網路;之後加入真主機時，`-uiTesting` 仍要維持這個保證。
@main
struct PurrdrApp: App {
    private let agentList: AgentListModel
    private let terminals: PaneTerminalClient
    private let workspaceActions: WorkspaceActionsModel
    private let navigation = TopNavigationModel()
    private let member: MemberModel
    private let client: HerdrClient
    private let transcripts: TranscriptReader
    /// 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
    private let conversationCache = InMemoryConversationCache()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let uiTesting = arguments.contains("-uiTesting")
        // UI 測試情境：桌機正在操作 Demo 的 Pane。
        let scenario: DemoHost.Scenario = arguments.contains("-demoPaneInUse") ? .paneInUse : .standard
        let channel: any HostChannel = DemoHost(scenario: scenario)
        let client = HerdrClient(channel: channel)
        let transcripts = TranscriptReader(channel: channel)
        let agentList = AgentListModel(client: client, transcripts: transcripts)
        // UI 測試每次啟動都從空白的釘選、靜音開始，不讀寫這台模擬器的 UserDefaults。
        let preferences: any ChatPreferencesStore = uiTesting
            ? InMemoryChatPreferencesStore() : UserDefaultsChatPreferencesStore()
        self.client = client
        self.transcripts = transcripts
        self.agentList = agentList
        terminals = PaneTerminalClient(channel: channel)
        workspaceActions = WorkspaceActionsModel(client: client, preferences: preferences, refresh: { await agentList.load() })
        member = Self.makeMember(uiTesting: uiTesting)
    }

    /// UI 測試模式：權杖只放記憶體(不碰 Keychain)、後台指向不存在的位址(不連網路)。
    private static func makeMember(uiTesting: Bool) -> MemberModel {
        let baseURL = uiTesting ? URL(string: "https://backend.invalid")! : BackendConfiguration.baseURL
        let tokenStore: any TokenStore = uiTesting ? InMemoryTokenStore() : KeychainTokenStore()
        return MemberModel(
            session: MemberSession(transport: URLSessionBackendTransport(baseURL: baseURL), tokenStore: tokenStore),
            google: GoogleSignIn(configuration: GoogleSignIn.Configuration(clientID: BackendConfiguration.googleClientID))
        )
    }

    var body: some Scene {
        WindowGroup {
            TopNavigationView(
                navigation: navigation, agentList: agentList, member: member, workspaceActions: workspaceActions
            ) { paneID, sessionID in
                ConversationModel(
                    client: client, transcripts: transcripts, paneID: paneID, knownSessionID: sessionID, cache: conversationCache
                )
            } terminal: { [terminals] paneID, title in
                PaneTerminalModel(client: terminals, paneID: paneID, title: title)
            }
        }
    }
}
