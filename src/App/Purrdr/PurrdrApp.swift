import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrFeatures
import SwiftUI

/// 唯一的 composition root:組裝主機儲存、主機通道與畫面 model。
///
/// 已存的主機經真 SSH(swift-nio-ssh)連線;沒有主機時用 Demo 主機。UI 測試以 `-uiTesting` 啟動，
/// 一律只用 Demo 主機：主機存在記憶體、不碰 Keychain,任何主機的通道也都是 Demo 主機，不連網路。
@main
struct PurrdrApp: App {
    @State private var hosts: HostsModel
    private let navigation = TopNavigationModel()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        // UI 測試情境：桌機正在操作 Demo 的 Pane。
        let scenario: DemoHost.Scenario = arguments.contains("-demoPaneInUse") ? .paneInUse : .standard
        let demo = DemoHost(scenario: scenario)
        // 對話快取。目前存在記憶體(app 執行期間);持久化(SwiftData)在之後的票。
        let cache = InMemoryConversationCache()
        let hosts: HostsModel
        if arguments.contains("-uiTesting") {
            hosts = HostsModel(store: EphemeralHostStore(), demoChannel: demo, conversationCache: cache, makeChannel: { _, _ in demo })
        } else {
            hosts = HostsModel(store: KeychainHostStore(), demoChannel: demo, conversationCache: cache) { endpoint, pin in
                SSHHostChannel(endpoint: endpoint, hostKeyPin: pin)
            }
        }
        hosts.load()
        _hosts = State(initialValue: hosts)
    }

    var body: some Scene {
        WindowGroup {
            TopNavigationView(navigation: navigation, hosts: hosts)
        }
    }
}
