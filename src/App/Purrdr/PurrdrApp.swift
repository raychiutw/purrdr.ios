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
    private let navigation = TopNavigationModel()
    private let member: MemberModel
    private let client: HerdrClient
    private let transcripts: TranscriptReader
    /// 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
    private let conversationCache = InMemoryConversationCache()

    init() {
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        let channel: any HostChannel = DemoHost()
        client = HerdrClient(channel: channel)
        transcripts = TranscriptReader(channel: channel)
        agentList = AgentListModel(client: client, transcripts: transcripts)
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
            TopNavigationView(navigation: navigation, agentList: agentList, member: member) { paneID, sessionID in
                ConversationModel(
                    client: client, transcripts: transcripts, paneID: paneID, knownSessionID: sessionID, cache: conversationCache
                )
            }
        }
    }
}
