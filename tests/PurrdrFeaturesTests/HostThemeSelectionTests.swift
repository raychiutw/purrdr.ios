#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機主題跟著選取中主機(#23 × #39;DESIGN.md:選取中主機決定套用誰的主題)。
/// 兩台主機都已同意主機主題，各自的 herdr 主題不同;主機是本機 `/bin/sh` + 各自的暫存家目錄。
@MainActor
@Suite("主機主題跟著選取中主機")
struct HostThemeSelectionTests {
    static let pin = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
    static let studio = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "studio", username: "demo"), operatingSystem: .macOS, hostKeyPin: pin)
    static let lab = HostConfiguration(
        name: "Lab", endpoint: SSHEndpoint(host: "lab", username: "demo"), operatingSystem: .linux, hostKeyPin: pin)

    let shells: [String: LocalShellHost]
    let model: HostsModel

    init() throws {
        let studioShell = try LocalShellHost.temporary()
        _ = try studioShell.write(Data("[theme]\nname = \"dracula\"\n".utf8), to: ".config/herdr/config.toml")
        let labShell = try LocalShellHost.temporary()
        _ = try labShell.write(Data("[theme]\nname = \"nord\"\n".utf8), to: ".config/herdr/config.toml")
        let shells = ["studio": studioShell, "lab": labShell]
        self.shells = shells

        let store = MemoryHostStore()
        store.hosts = [Self.studio, Self.lab]
        let consent = InMemoryHostWriteConsentStore()
        consent.grant(HostThemeHost.feature.id, host: Self.studio.id.uuidString)
        consent.grant(HostThemeHost.feature.id, host: Self.lab.id.uuidString)
        model = HostsModel(store: store, demoChannel: FakeHost(), hostConsent: consent) { endpoint, _, _ in
            if let shell = shells[endpoint.host] { return shell }
            return FakeHost()
        }
        model.load()
    }

    @Test("換選取中主機：主題改成那台主機的 herdr 主題;切回來立刻是原來那台的(不必等下一次輪詢)")
    func themeFollowsSelection() async {
        model.select(.host(Self.studio.id))
        await model.hostTheme.refresh()
        #expect(model.hostTheme.theme?.name == "dracula")

        model.select(.host(Self.lab.id))
        #expect(model.hostTheme.state == .on, "換到另一台已同意的主機，主題卻是關的")
        await model.hostTheme.refresh()
        #expect(model.hostTheme.theme?.name == "nord", "換了選取中主機，主題還是上一台的")

        model.select(.host(Self.studio.id))
        #expect(model.hostTheme.theme?.name == "dracula", "切回來時主題不是這台的")
    }

    @Test("沒同意主題的主機：換過去就回到 App 配色，設定頁的開關是關的")
    func hostWithoutConsentUsesAppColors() async {
        model.select(.host(Self.studio.id))
        await model.hostTheme.refresh()
        #expect(model.hostTheme.theme?.name == "dracula")

        model.select(.demo)
        #expect(model.hostTheme.state == .off)
        #expect(model.hostTheme.theme == nil)
    }
}
#endif
