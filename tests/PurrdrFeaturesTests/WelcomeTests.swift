import Foundation
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 第一次開啟的歡迎頁(#34;HIG Onboarding:短、可跳過，跳過後不再出現但在設定找得到)。
@MainActor
@Suite("歡迎頁")
struct WelcomeTests {
    @Test("第一次開啟：視窗開出歡迎頁;之後的啟動(或另一個視窗)不再出現")
    func showsOnlyOnFirstLaunch() {
        let welcome = WelcomeModel(store: InMemoryWelcomeStore())

        let first = TopNavigationModel()
        first.launched(welcome: welcome)
        #expect(first.sheet == .welcome)

        let second = TopNavigationModel()
        second.launched(welcome: welcome)
        #expect(second.sheet == nil)
    }

    @Test("看過的紀錄存在 UserDefaults:重開 app 不再出現")
    func seenSurvivesRelaunch() throws {
        let suite = "WelcomeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = TopNavigationModel()
        first.launched(welcome: WelcomeModel(store: UserDefaultsWelcomeStore(defaults: defaults)))
        #expect(first.sheet == .welcome)

        let relaunched = TopNavigationModel()
        relaunched.launched(welcome: WelcomeModel(store: UserDefaultsWelcomeStore(defaults: defaults)))
        #expect(relaunched.sheet == nil)
    }

    @Test("已經看過(UI 測試預設):啟動時不出現;設定頁可以再打開")
    func seenStoreSkipsButSettingsReopens() {
        let navigation = TopNavigationModel()
        navigation.launched(welcome: WelcomeModel(store: InMemoryWelcomeStore(hasSeen: true)))
        #expect(navigation.sheet == nil)

        navigation.sheet = .settings
        navigation.showWelcome()
        #expect(navigation.sheet == .welcome)
    }

    @Test("歡迎頁的「Try the Demo」走 enterDemo():空列表(尚未進入 Demo)下也進得去,並收起 sheet")
    func tryDemoEntersDemo() {
        let hosts = HostsModel(store: MemoryHostStore(), demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        hosts.demoEntered = false
        let navigation = TopNavigationModel()
        navigation.sheet = .welcome

        navigation.welcomeTryDemo(hosts: hosts)

        #expect(hosts.demoEntered)
        #expect(navigation.sheet == nil)
    }

    @Test("歡迎頁的「新增主機」換成主機 sheet 並直接進新增主機引導(同一時間只開一個 sheet)")
    func addHostOpensHosts() {
        let navigation = TopNavigationModel()
        navigation.launched(welcome: WelcomeModel(store: InMemoryWelcomeStore()))

        navigation.welcomeAddHost()

        #expect(navigation.sheet == .hosts)
        #expect(navigation.pendingAddHost)
    }
}
