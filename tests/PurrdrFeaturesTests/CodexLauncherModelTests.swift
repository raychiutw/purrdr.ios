#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 設定頁的「Codex 啟動器」(行為規格 §4.2、ADR-0002):每台主機個別同意、說明以哪個使用者安裝、可完整移除。
/// 主機是本機 `/bin/sh` + 暫存家目錄。【未實測】啟動器本身在真實 Codex 上沒驗證過。
@MainActor
@Suite("Codex 啟動器")
struct CodexLauncherModelTests {
    let host: LocalShellHost
    let consent = InMemoryHostWriteConsentStore()

    init() throws {
        host = try LocalShellHost.temporary()
    }

    func model(hostID: String = "mac") -> CodexLauncherModel {
        CodexLauncherModel(host: CodexLauncherHost(channel: host), hostID: hostID, consent: consent)
    }

    @Test("還沒同意：關閉，不碰主機")
    func offUntilConsent() {
        let model = model()
        #expect(model.state == .off)
        #expect(host.commands.isEmpty)
    }

    @Test("打開：先檢查主機再請使用者確認;確認前主機不變，取消就回到關閉")
    func asksForConsent() async throws {
        let model = model()
        let before = try DirectorySnapshot(of: host.home)

        await model.request()
        guard case .confirming(let user) = model.state else {
            Issue.record("沒有請使用者確認:\(model.state)")
            return
        }
        #expect(!user.isEmpty)
        #expect(try DirectorySnapshot(of: host.home) == before)

        model.cancelConsent()
        #expect(model.state == .off)
        #expect(!consent.isGranted("codex-launcher", host: "mac"))
    }

    @Test("確認後安裝並記住同意;移除後主機與安裝前完全相同、撤銷同意")
    func installAndRemove() async throws {
        let model = model()
        let before = try DirectorySnapshot(of: host.home)

        await model.request()
        await model.confirm()
        #expect(model.state == .on)
        #expect(consent.isGranted("codex-launcher", host: "mac"))
        #expect(FileManager.default.isExecutableFile(atPath: host.url(".local/bin/codex").path))
        // 同意以主機為單位：重建 model 仍是開啟。
        #expect(self.model().state == .on)
        #expect(self.model(hostID: "other").state == .off)

        await model.turnOff()
        #expect(model.state == .off)
        #expect(!consent.isGranted("codex-launcher", host: "mac"))
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("~/.local/bin/codex 已經是使用者自己的：不安裝，說明原因")
    func refusesExistingCodex() async throws {
        let url = try host.write(Data("#!/bin/sh\n".utf8), to: ".local/bin/codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let before = try DirectorySnapshot(of: host.home)
        let model = model()

        await model.request()

        #expect(model.state == .off)
        #expect(model.message != nil)
        #expect(try DirectorySnapshot(of: host.home) == before)
    }
}
#endif
