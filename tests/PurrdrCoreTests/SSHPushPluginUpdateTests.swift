#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// SSH 主機的推播外掛自動更新(#432):版本落後才 `herdr plugin update`,沒裝不代裝,失敗丟出說明(呼叫端不打擾使用者)。
/// 以 `LocalShellHost` 與假 herdr 執行，不碰真主機。
@Suite("推播外掛自動更新(SSH)")
struct SSHPushPluginUpdateTests {
    let host: LocalShellHost

    init() throws {
        host = try LocalShellHost.temporary()
        try FakeHerdrPluginCLI.install(on: host)
    }

    func installer() -> SSHPushPluginInstaller {
        SSHPushPluginInstaller(
            channel: host, herdr: HerdrInstallation(), deviceID: PushDeviceID(rawValue: "0123456789abcdef")!,
            pluginSource: "raychiutw/purrdr.host/host-plugin")
    }

    /// 經 Purrdr 安裝(留下 `~/.purrdr/push-plugin/` 的安裝紀錄),外掛版本回報 0.1.0。
    func installByPurrdr() async throws {
        try await installer().install(PushPairingFile(
            endpoint: URL(string: "https://backend.test/v1/push")!, key: .generate(), muted: []))
    }

    func calls() throws -> [String] { try FakeHerdrPluginCLI.calls(on: host) }

    @Test("外掛版本落後：更新到最新版")
    func updatesOutdatedPlugin() async throws {
        try await installByPurrdr()  // 假 herdr 預設回報 0.1.0

        let updated = try await installer().updatePluginIfNeeded()

        #expect(updated)
        #expect(try calls().contains("plugin update purrdr.push --yes"))
        #expect(FakeHerdrPluginCLI.pluginVersion(on: host) == "0.2.1")
    }

    @Test("已是最新版：不執行 plugin update")
    func skipsCurrentPlugin() async throws {
        try await installByPurrdr()
        try host.write(Data("0.2.1\n".utf8), to: "fake/version")

        let updated = try await installer().updatePluginIfNeeded()

        #expect(!updated)
        #expect(try !calls().contains { $0.hasPrefix("plugin update") })
    }

    @Test("比 app 認得的版本更新：不更新")
    func skipsNewerPlugin() async throws {
        try await installByPurrdr()
        try host.write(Data("0.3.0\n".utf8), to: "fake/version")

        #expect(try await installer().updatePluginIfNeeded() == false)
        #expect(try !calls().contains { $0.hasPrefix("plugin update") })
    }

    @Test("使用者自己裝的外掛(沒有 Purrdr 的安裝紀錄):不更新,不動不是 Purrdr 裝的東西(ADR-0002)")
    func doesNotUpdateUserInstalledPlugin() async throws {
        try host.write(Data(), to: "fake/installed")  // herdr 上已有 purrdr.push,但不是 Purrdr 裝的

        let updated = try await installer().updatePluginIfNeeded()

        #expect(!updated)
        #expect(try !calls().contains { $0.hasPrefix("plugin update") })
        #expect(FakeHerdrPluginCLI.pluginVersion(on: host) == "0.1.0")
    }

    @Test("沒裝外掛：不代裝也不更新")
    func doesNotInstallMissingPlugin() async throws {
        let updated = try await installer().updatePluginIfNeeded()

        #expect(!updated)
        #expect(try !calls().contains { $0.hasPrefix("plugin update") || $0.hasPrefix("plugin install") })
    }

    @Test("更新失敗：丟出說明，外掛維持原樣")
    func reportsUpdateFailure() async throws {
        try await installByPurrdr()
        try host.write(Data(), to: "fake/update-fails")

        await #expect(throws: PushPluginError.pluginUpdateFailed("git fetch failed")) {
            try await installer().updatePluginIfNeeded()
        }
        #expect(FakeHerdrPluginCLI.pluginVersion(on: host) == "0.1.0")
    }

    @Test("看不懂版本(例如 Demo 主機)：不更新")
    func skipsUnparsableVersion() async throws {
        try await installByPurrdr()
        try host.write(Data("dev\n".utf8), to: "fake/version")

        #expect(try await installer().updatePluginIfNeeded() == false)
        #expect(try !calls().contains { $0.hasPrefix("plugin update") })
    }
}
#endif
