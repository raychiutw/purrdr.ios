import Crypto
import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Synchronization
import Testing

/// 存在記憶體裡的祕密儲存(Seam 3 的假實作)。記錄讀取次數，驗證「撥號時才讀」。
final class MemorySecretStore: HostSecretStore {
    private let state = Mutex<(secrets: [UUID: HostSecret], reads: Int, failWrites: Bool)>(([:], 0, false))

    var reads: Int { state.withLock { $0.reads } }

    func failWrites() { state.withLock { $0.failWrites = true } }

    func secret(for host: UUID) throws -> HostSecret? {
        state.withLock {
            $0.reads += 1
            return $0.secrets[host]
        }
    }

    func setSecret(_ secret: HostSecret?, for host: UUID) throws {
        try state.withLock {
            if $0.failWrites { throw SaveFailed() }
            $0.secrets[host] = secret
        }
    }

    func stored(_ host: UUID) -> HostSecret? { state.withLock { $0.secrets[host] } }
}

/// 從憑證來源取出憑證，轉成可比較的描述。
func describe(_ provider: SSHCredentialProvider?) async throws -> String {
    guard let provider else { return "沒有開連線" }
    switch try await provider() {
    case .none: return "none"
    case .password(let password): return "password:\(password)"
    case .privateKey(let key): return "key:\(key.publicKey.openSSH)"
    }
}

@MainActor
@Suite("新增主機(OpenSSH)")
struct HostEditorOpenSSHTests {
    static let pin = HostEditorModelTests.fingerprint

    static func model(
        secrets: MemorySecretStore = MemorySecretStore(), deviceKey: any DeviceKey = EphemeralDeviceKey(),
        store: MemoryHostStore = MemoryHostStore(), editing: HostConfiguration? = nil, factory: ChannelFactory
    ) -> HostEditorModel {
        let model = HostEditorModel(
            store: store, editing: editing, credentials: HostCredentials(secrets: secrets, deviceKey: deviceKey),
            makeChannel: factory.make)
        if editing == nil {
            HostEditorModelTests.fill(model)
            model.connectionMethod = .openSSH
        }
        return model
    }

    static let existing = HostConfiguration(
        name: "Studio", endpoint: SSHEndpoint(host: "ray-mac-mini", username: "demo"), connectionMethod: .openSSH,
        authentication: .password, hostKeyPin: pin)

    @Test("密碼：連線測試用輸入的密碼登入;儲存後密碼只在祕密儲存，主機設定裡沒有")
    func passwordIsUsedAndStoredSeparately() async throws {
        let secrets = MemorySecretStore()
        let store = MemoryHostStore()
        let factory = ChannelFactory(await HostEditorModelTests.healthyHost())
        let model = Self.model(secrets: secrets, store: store, factory: factory)
        model.authentication = .password
        model.password = "hunter2"

        await model.test()
        let saved = try #require(model.save())

        #expect(try await describe(factory.credentials.first) == "password:hunter2")
        #expect(saved.connectionMethod == .openSSH)
        #expect(saved.authentication == .password)
        #expect(secrets.stored(saved.id) == .password("hunter2"))
        let encoded = String(decoding: try JSONEncoder().encode(store.hosts), as: UTF8.self)
        #expect(!encoded.contains("hunter2"), "密碼跟主機設定存在一起(主機同步會帶走)")
    }

    @Test("這支裝置的金鑰：顯示公鑰與指紋;連線測試用它登入;不存任何祕密")
    func deviceKeySignsIn() async throws {
        let secrets = MemorySecretStore()
        let deviceKey = EphemeralDeviceKey(comment: "purrdr@test")
        let factory = ChannelFactory(await HostEditorModelTests.healthyHost())
        let model = Self.model(secrets: secrets, deviceKey: deviceKey, factory: factory)
        model.authentication = .deviceKey

        await model.loadDeviceKey()
        let shown = try #require(model.devicePublicKey)
        await model.test()
        let saved = try #require(model.save())

        let signing = try deviceKey.signingKey().publicKey
        #expect(shown == signing.withComment("purrdr@test"))
        #expect(shown.fingerprint == signing.fingerprint)
        #expect(try await describe(factory.credentials.first) == "key:\(signing.openSSH)")
        #expect(saved.authentication == .deviceKey)
        #expect(secrets.stored(saved.id) == nil)
    }

    #if os(macOS)
    @Test("匯入金鑰：檢查後顯示公鑰;連線測試用它登入;儲存時金鑰存在祕密儲存")
    func importedKeySignsIn() async throws {
        let generated = try SSHKeygen.generate(type: "ed25519")
        defer { generated.remove() }
        let secrets = MemorySecretStore()
        let factory = ChannelFactory(await HostEditorModelTests.healthyHost())
        let model = Self.model(secrets: secrets, factory: factory)
        model.authentication = .importedKey
        model.privateKeyText = generated.privateText

        await model.checkKey()
        #expect(model.keyCheck == .valid(SSHPublicKey(openSSH: generated.publicKeyWithoutComment)))
        await model.test()
        let saved = try #require(model.save())

        #expect(try await describe(factory.credentials.first) == "key:\(generated.publicKeyWithoutComment)")
        #expect(secrets.stored(saved.id) == .privateKey(generated.privateText, passphrase: nil))
    }

    @Test("匯入 RSA:說明不支援、不能測試;一鍵改用這支裝置的金鑰")
    func rsaOffersDeviceKey() async throws {
        let generated = try SSHKeygen.generate(type: "rsa", bits: 2048)
        defer { generated.remove() }
        let model = Self.model(factory: ChannelFactory())
        model.authentication = .importedKey
        model.privateKeyText = generated.privateText

        await model.checkKey()
        #expect(model.keyCheck == .invalid(.rsaNotSupported))
        #expect(!model.canTest)

        model.useDeviceKeyInstead()
        #expect(model.authentication == .deviceKey)
        #expect(model.privateKeyText.isEmpty, "不支援的私鑰留在畫面上")
        #expect(model.canTest)
    }

    @Test("有 passphrase 的金鑰：說明要先在電腦上移除 passphrase,不能測試")
    func passphraseProtectedKey() async throws {
        let generated = try SSHKeygen.generate(type: "ecdsa", passphrase: "secret")
        defer { generated.remove() }
        let model = Self.model(factory: ChannelFactory())
        model.authentication = .importedKey
        model.privateKeyText = generated.privateText

        await model.checkKey()

        #expect(model.keyCheck == .invalid(.passphraseProtected))
        #expect(!model.canTest)
        #expect(HostErrorText.keyImportMessage(.passphraseProtected).contains("ssh-keygen -p -N \"\" -f"))
    }
    #endif

    @Test("密碼或金鑰沒填就不能測試")
    func secretIsRequired() {
        let model = Self.model(factory: ChannelFactory())
        model.authentication = .password
        #expect(!model.canTest)
        model.password = "x"
        #expect(model.canTest)
        model.authentication = .importedKey
        #expect(!model.canTest)
    }

    @Test("測試之後改了密碼，要重新測試才能儲存")
    func changingSecretInvalidatesTest() async {
        let model = Self.model(factory: ChannelFactory(await HostEditorModelTests.healthyHost()))
        model.authentication = .password
        model.password = "hunter2"

        await model.test()
        #expect(model.canSave)
        model.password = "hunter3"
        #expect(!model.canSave)
    }

    @Test("編輯主機時密碼留空 = 保留原本的密碼:測試用已存的密碼，儲存時不覆寫")
    func blankSecretKeepsStored() async throws {
        let secrets = MemorySecretStore()
        try secrets.setSecret(.password("stored"), for: Self.existing.id)
        let factory = ChannelFactory(await HostEditorModelTests.healthyHost())
        let model = Self.model(secrets: secrets, editing: Self.existing, factory: factory)

        #expect(!model.hasChanges)
        #expect(model.canTest)
        await model.test()
        _ = try #require(model.save())

        #expect(try await describe(factory.credentials.first) == "password:stored")
        #expect(secrets.stored(Self.existing.id) == .password("stored"))
    }

    @Test("改成 Tailscale SSH 後儲存：刪掉這台主機的祕密")
    func switchingToTailscaleDeletesSecret() async throws {
        let secrets = MemorySecretStore()
        try secrets.setSecret(.password("stored"), for: Self.existing.id)
        let factory = ChannelFactory(await HostEditorModelTests.healthyHost())
        let model = Self.model(secrets: secrets, editing: Self.existing, factory: factory)

        model.connectionMethod = .tailscaleSSH
        await model.test()
        let saved = try #require(model.save())

        #expect(try await describe(factory.credentials.first) == "none")
        #expect(saved.authentication == nil)
        #expect(secrets.stored(Self.existing.id) == nil)
    }

    @Test("祕密寫不進 Keychain:留在編輯器說明原因，主機也不存")
    func secretWriteFailureStaysInEditor() async {
        let secrets = MemorySecretStore()
        secrets.failWrites()
        let store = MemoryHostStore()
        let model = Self.model(secrets: secrets, store: store, factory: ChannelFactory(await HostEditorModelTests.healthyHost()))
        model.authentication = .password
        model.password = "hunter2"

        await model.test()
        #expect(model.save() == nil)

        guard case .failed = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(store.hosts.isEmpty)
    }

    @Test("主機拒絕密碼：說明檢查使用者名稱與密碼(不提 Tailscale)")
    func rejectedPasswordExplainsWhy() async {
        let rejecting = FakeHost()
        await rejecting.failConnection(with: SSHConnectionError.authenticationFailed)
        let model = Self.model(factory: ChannelFactory(rejecting))
        model.authentication = .password
        model.password = "hunter2"

        await model.test()

        guard case .failed(let message) = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(message.contains("password"))
        #expect(!message.contains("Tailscale"))
    }
}

@MainActor
@Suite("OpenSSH 主機的連線")
struct OpenSSHHostConnectionTests {
    @Test("選取 OpenSSH 主機時不讀祕密;第一次撥號才讀;祕密不在時回報專屬錯誤")
    func secretIsReadLazily() async throws {
        let secrets = MemorySecretStore()
        let host = HostEditorOpenSSHTests.existing
        let store = MemoryHostStore()
        store.hosts = [host]
        let factory = ChannelFactory(FakeHost())
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), credentials: HostCredentials(secrets: secrets, deviceKey: EphemeralDeviceKey()),
            makeChannel: factory.make)

        model.load()
        #expect(secrets.reads == 0, "選取主機時就讀了 Keychain")

        await #expect(throws: HostCredentialError.missingSecret) { try await describe(factory.credentials.first) }
        try secrets.setSecret(.password("hunter2"), for: host.id)
        #expect(try await describe(factory.credentials.first) == "password:hunter2")
    }

    @Test("移除主機：先刪這台主機的祕密，再刪主機設定(行為規格 §8.1)")
    func removingHostDeletesSecret() async throws {
        let secrets = MemorySecretStore()
        let host = HostEditorOpenSSHTests.existing
        try secrets.setSecret(.password("hunter2"), for: host.id)
        let store = MemoryHostStore()
        store.hosts = [host]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), credentials: HostCredentials(secrets: secrets, deviceKey: EphemeralDeviceKey()),
            makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        try await model.delete(host.id)

        #expect(secrets.stored(host.id) == nil, "移除主機後祕密還留在 Keychain")
        #expect(store.hosts.isEmpty)
    }

    @Test("祕密刪不掉時不刪主機(避免留下找不到主人的祕密)")
    func secretDeleteFailureKeepsHost() async throws {
        let secrets = MemorySecretStore()
        secrets.failWrites()
        let host = HostEditorOpenSSHTests.existing
        let store = MemoryHostStore()
        store.hosts = [host]
        let model = HostsModel(
            store: store, demoChannel: FakeHost(), credentials: HostCredentials(secrets: secrets, deviceKey: EphemeralDeviceKey()),
            makeChannel: ChannelFactory(FakeHost()).make)
        model.load()

        await #expect(throws: SaveFailed.self) { try await model.delete(host.id) }
        #expect(store.hosts == [host])
    }
}
