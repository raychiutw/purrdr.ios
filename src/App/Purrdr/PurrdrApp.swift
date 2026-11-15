import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import SwiftUI

/// 唯一的 composition root:組裝主機儲存、主機通道、Purrdr 後台與畫面 model。
///
/// 已存的主機經真 SSH(swift-nio-ssh)連線;沒有主機時用 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機：主機存在記憶體、不碰 Keychain,任何主機的通道也都是 Demo 主機，不連網路。
@main
struct PurrdrApp: App {
    @State private var hosts: HostsModel
    private let navigation = TopNavigationModel()
    private let member: MemberModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let uiTesting = arguments.contains("-uiTesting")
        // UI 測試情境：桌機正在操作 Demo 的 Pane。
        let scenario: DemoHost.Scenario = arguments.contains("-demoPaneInUse") ? .paneInUse : .standard
        let demo = DemoHost(scenario: scenario)
        // 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
        let cache = InMemoryConversationCache()
        // UI 測試每次啟動都從空白的釘選、靜音開始，不讀寫這台模擬器的 UserDefaults。
        let preferences: any ChatPreferencesStore = uiTesting
            ? InMemoryChatPreferencesStore() : UserDefaultsChatPreferencesStore()
        let hosts: HostsModel
        if uiTesting {
            // 祕密只放記憶體;裝置金鑰是軟體金鑰(模擬器沒有 Secure Enclave)。
            let credentials = HostCredentials(secrets: EphemeralHostSecretStore(), deviceKey: EphemeralDeviceKey())
            hosts = HostsModel(
                store: EphemeralHostStore(), demoChannel: demo, conversationCache: cache, preferences: preferences,
                credentials: credentials, makeChannel: { _, _, _ in demo })
        } else {
            // 公鑰註解只帶裝置種類(「iPhone」「iPad」),不帶使用者取的裝置名稱。
            let credentials = HostCredentials(
                secrets: KeychainHostSecretStore(), deviceKey: SecureEnclaveDeviceKey(comment: "purrdr@\(UIDevice.current.model)"))
            hosts = HostsModel(
                store: KeychainHostStore(), demoChannel: demo, conversationCache: cache, preferences: preferences,
                credentials: credentials
            ) { endpoint, pin, credential in
                SSHHostChannel(endpoint: endpoint, hostKeyPin: pin, credential: credential)
            }
        }
        hosts.load()
        _hosts = State(initialValue: hosts)
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
            TopNavigationView(navigation: navigation, hosts: hosts, member: member)
        }
    }
}
