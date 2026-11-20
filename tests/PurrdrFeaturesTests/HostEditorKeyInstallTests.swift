import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 新增 SSH 主機時用密碼加入這支裝置的公鑰(#285)。
@MainActor
@Suite("新增主機：用密碼加入公鑰")
struct HostEditorKeyInstallTests {
    static let pin = HostEditorModelTests.fingerprint
    static let authorizedKeys = ".ssh/authorized_keys"

    /// 用密碼登入、還沒有這支裝置公鑰的 macOS 主機。
    static func passwordOnlyHost(_ files: [String: Data] = [:]) async -> FakeHost {
        let host = FakeHost()
        await host.expect(HerdrCommand.operatingSystem, reply: FakeReply(stdout: Data("Darwin\n".utf8)))
        await host.serveHomeFiles(files)
        return host
    }

    static func model(
        consent: InMemoryHostWriteConsentStore = InMemoryHostWriteConsentStore(), secrets: MemorySecretStore = MemorySecretStore(),
        store: MemoryHostStore = MemoryHostStore(), factory: ChannelFactory
    ) async -> HostEditorModel {
        let model = HostEditorModel(
            store: store, credentials: HostCredentials(secrets: secrets, deviceKey: EphemeralDeviceKey(comment: "purrdr@iPhone")),
            consent: consent, makeChannel: factory.make)
        HostEditorModelTests.fill(model)
        model.connectionMethod = .openSSH
        model.authentication = .deviceKey
        await model.loadDeviceKey()
        return model
    }

    @Test("說明並徵求同意之前，不連主機、不寫任何東西")
    func asksBeforeWriting() async {
        let factory = ChannelFactory(await Self.passwordOnlyHost())
        let model = await Self.model(factory: factory)
        model.keyInstallPassword = "hunter2"

        #expect(model.canInstallDeviceKey)
        model.requestKeyInstall()

        #expect(model.phase == .confirmKeyInstall)
        #expect(factory.credentials.isEmpty)
        model.dismissPrompt()
        #expect(model.phase == .editing)
        #expect(factory.credentials.isEmpty)
    }

    @Test("同意後：用密碼登入一次寫入公鑰，接著用金鑰測試;儲存為金鑰登入，密碼不寫進 Keychain")
    func installsKeyThenUsesIt() async throws {
        let consent = InMemoryHostWriteConsentStore()
        let secrets = MemorySecretStore()
        let target = await Self.passwordOnlyHost()
        let factory = ChannelFactory(target, await HostEditorModelTests.healthyHost())
        let model = await Self.model(consent: consent, secrets: secrets, factory: factory)
        model.keyInstallPassword = "hunter2"

        model.requestKeyInstall()
        await model.confirmKeyInstall()

        let publicKey = try #require(model.devicePublicKey)
        #expect(try await describe(factory.credentials.first) == "password:hunter2")
        #expect(await target.homeFiles[Self.authorizedKeys] == Data((publicKey.openSSH + "\n").utf8))
        #expect(publicKey.openSSH.hasSuffix(" purrdr@iPhone"))
        #expect(await target.disconnectCount == 1, "寫入公鑰的暫時連線沒有拆掉")
        #expect(try await describe(factory.credentials.last).hasPrefix("key:"))
        #expect(model.keyInstallOutcome == .added)
        #expect(model.keyInstallPassword.isEmpty, "密碼留在畫面上")
        guard case .tested = model.phase else { Issue.record("沒有接著用金鑰測試:\(model.phase)"); return }

        let saved = try #require(model.save())
        #expect(saved.authentication == .deviceKey)
        #expect(secrets.stored(saved.id) == nil)
        #expect(consent.isGranted(AuthorizedKeyInstaller.feature.id, host: saved.id.uuidString))
    }

    @Test("公鑰已在主機上：不重複加入，直接用金鑰測試")
    func keyAlreadyThere() async throws {
        let deviceKey = EphemeralDeviceKey(comment: "purrdr@iPhone")
        let existing = Data((try deviceKey.publicKey().openSSH + "\n").utf8)
        let target = await Self.passwordOnlyHost([Self.authorizedKeys: existing])
        let factory = ChannelFactory(target, await HostEditorModelTests.healthyHost())
        let model = HostEditorModel(
            store: MemoryHostStore(), credentials: HostCredentials(deviceKey: deviceKey), makeChannel: factory.make)
        HostEditorModelTests.fill(model)
        model.connectionMethod = .openSSH
        await model.loadDeviceKey()
        model.keyInstallPassword = "hunter2"

        model.requestKeyInstall()
        await model.confirmKeyInstall()

        #expect(model.keyInstallOutcome == .alreadyPresent)
        #expect(await target.homeFiles == [Self.authorizedKeys: existing])
        guard case .tested = model.phase else { Issue.record("\(model.phase)"); return }
    }

    @Test("密碼不對：顯示原因、維持金鑰登入，可以改用手動指令")
    func wrongPasswordExplainsAndKeepsManualCommands() async {
        let rejecting = FakeHost()
        await rejecting.failConnection(with: SSHConnectionError.authenticationFailed)
        let model = await Self.model(factory: ChannelFactory(rejecting))
        model.keyInstallPassword = "wrong"

        model.requestKeyInstall()
        await model.confirmKeyInstall()

        guard case .keyInstallFailed(let message) = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(message.contains("password"))
        #expect(model.authentication == .deviceKey)
        #expect(!model.canSave)
        #expect(model.devicePublicKey != nil, "手動指令要用的公鑰不見了")
    }

    @Test("第一次連到這台主機：先確認 host key 指紋，信任後繼續寫入公鑰")
    func confirmsHostKeyThenContinues() async throws {
        let target = await Self.passwordOnlyHost()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), target, await HostEditorModelTests.healthyHost())
        let model = await Self.model(factory: factory)
        model.keyInstallPassword = "hunter2"

        model.requestKeyInstall()
        await model.confirmKeyInstall()
        #expect(model.phase == .confirmHostKey(Self.pin))

        await model.trustPresentedHostKey()

        #expect(factory.pins == [nil, Self.pin, Self.pin])
        #expect(try await describe(factory.credentials[1]) == "password:hunter2")
        #expect(model.keyInstallOutcome == .added)
        guard case .tested = model.phase else { Issue.record("\(model.phase)"); return }
    }
}
