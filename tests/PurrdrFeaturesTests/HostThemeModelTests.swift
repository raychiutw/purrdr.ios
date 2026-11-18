#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機主題(#23):每台主機個別同意後寫主題參考檔、讀主機 herdr 的配色;關閉時還原。
/// 主機是本機 `/bin/sh` + 暫存家目錄。
@MainActor
@Suite("主機主題")
struct HostThemeModelTests {
    let host: LocalShellHost
    let consent = InMemoryHostWriteConsentStore()

    init() throws {
        host = try LocalShellHost.temporary()
        _ = try host.write(Data("[theme]\nname = \"dracula\"\n".utf8), to: ".config/herdr/config.toml")
    }

    func model(hostID: String = "mac") -> HostThemeModel {
        HostThemeModel(host: HostThemeHost(channel: host), hostID: hostID, consent: consent, sleep: { _ in })
    }

    @Test("還沒同意：用 App 自己的配色，不碰主機")
    func offUntilConsent() async {
        let model = model()
        await model.refresh()
        #expect(model.state == .off)
        #expect(model.theme == nil)
        #expect(host.commands.isEmpty)
    }

    @Test("同意流程：先說明以哪個使用者寫入，確認後寫參考檔、記住同意、套用主機配色")
    func consentThenApply() async throws {
        let model = model()
        let before = try DirectorySnapshot(of: host.home)
        await model.requestTheme()
        #expect(model.state == .confirming(user: NSUserName()))
        #expect(try DirectorySnapshot(of: host.home) == before)

        await model.confirm()
        #expect(model.state == .on)
        #expect(consent.isGranted(HostThemeHost.feature.id, host: "mac"))
        #expect(model.theme?.name == "dracula")
        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr/theme/README.md").path))
    }

    @Test("取消：主機不變、不套用")
    func cancel() async throws {
        let model = model()
        await model.requestTheme()
        model.cancelConsent()
        #expect(model.state == .off)
        #expect(model.theme == nil)
        #expect(!consent.isGranted(HostThemeHost.feature.id, host: "mac"))
    }

    @Test("關閉：移除參考檔(家目錄與同意前完全相同)、撤銷同意、回到 App 配色")
    func turnOffRestores() async throws {
        let before = try DirectorySnapshot(of: host.home)
        let model = model()
        await model.requestTheme()
        await model.confirm()
        await model.turnOff()
        #expect(model.state == .off)
        #expect(model.theme == nil)
        #expect(!consent.isGranted(HostThemeHost.feature.id, host: "mac"))
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("已同意的主機：啟動就讀主題;讀取失敗保留目前的主題")
    func keepsThemeWhenReadFails() async throws {
        consent.grant(HostThemeHost.feature.id, host: "mac")
        let model = model()
        #expect(model.state == .on)
        await model.refresh()
        #expect(model.theme?.name == "dracula")

        try FileManager.default.removeItem(at: host.url(".config/herdr/config.toml"))
        try FileManager.default.createDirectory(at: host.url(".config/herdr/config.toml"), withIntermediateDirectories: true)
        await model.refresh()
        #expect(model.theme?.name == "dracula")
    }

    @Test("主機 config 改了：下次讀取就換配色")
    func picksUpChanges() async throws {
        consent.grant(HostThemeHost.feature.id, host: "mac")
        let model = model()
        await model.refresh()
        _ = try host.write(Data("[theme]\nname = \"nord\"\n".utf8), to: ".config/herdr/config.toml")
        await model.refresh()
        #expect(model.theme?.name == "nord")
    }

    @Test("config 沒變：之後的讀取帶已知版本(主機只回 unchanged),主題照舊")
    func laterReadsCarryKnownVersion() async throws {
        consent.grant(HostThemeHost.feature.id, host: "mac")
        let model = model()
        await model.refresh()
        await model.refresh()

        let request = try #require(host.commands.last.flatMap(HostFileRequest.init(command:)))
        guard case .readIfChanged(_, let known) = request else {
            Issue.record("第二次讀沒帶已知版本:\(request)")
            return
        }
        #expect(known[HostThemeHost.configPath] != nil)
        #expect(model.theme?.name == "dracula")
    }

    @Test("多個視窗同時套用同一台主機的主題：只有一個讀取迴圈")
    func windowsShareOneReader() async throws {
        consent.grant(HostThemeHost.feature.id, host: "mac")
        let sleeper = RecordingSleeper()
        let model = HostThemeModel(host: HostThemeHost(channel: host), hostID: "mac", consent: consent, sleep: sleeper.sleep)

        let first = Task { await model.liveUpdates.attach() }
        let second = Task { await model.liveUpdates.attach() }
        for _ in 0..<2000 where await sleeper.requested.isEmpty || model.liveUpdates.viewers < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await sleeper.requested == [.seconds(10)])
        #expect(host.commands.count == 1)
        first.cancel()
        second.cancel()
    }
}
#endif
