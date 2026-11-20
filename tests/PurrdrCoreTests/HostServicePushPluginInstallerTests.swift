import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的推播外掛安裝(#265):經主機服務的 `push.status`／`push.install`／`push.remove`(0.6.0 起)。
@Suite("主機服務的推播外掛安裝")
struct HostServicePushPluginInstallerTests {
    static let endpoint = URL(string: "https://backend.test/v1/push")!
    static let deviceID = PushDeviceID(rawValue: "aaaaaaaaaaaaaaaa")!

    private static func start(_ settings: FakeHostService.Settings = .init(hostServiceVersion: "0.6.0")) async throws -> FakeHostService {
        try await FakeHostService.start(settings)
    }

    private static func installer(_ service: FakeHostService, token: String = "token-ok") -> HostServicePushPluginInstaller {
        HostServicePushPluginInstaller(
            connection: HTTPSHostConnection(address: service.address, deviceToken: { token }), deviceID: deviceID)
    }

    @Test("主機服務 0.6.0 以前：每個操作都丟 hostServiceOutdated,不送 push 訊息")
    func outdatedHostServiceIsReported() async throws {
        let service = try await Self.start(.init(hostServiceVersion: "0.5.0"))
        defer { Task { await service.stop() } }
        let installer = Self.installer(service)

        await #expect(throws: PushPluginError.hostServiceOutdated(installed: "0.5.0")) { try await installer.status() }
        await #expect(throws: PushPluginError.hostServiceOutdated(installed: "0.5.0")) {
            try await installer.install(PushPairingFile(endpoint: Self.endpoint, key: .generate()))
        }
        #expect(service.messages(ofType: "push.status").isEmpty)
        #expect(service.messages(ofType: "push.install").isEmpty)
    }

    @Test("安裝送出裝置 id 與配對內容(網址、密鑰、靜音清單)")
    func installSendsThePairing() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let key = PushPairingKey.generate()

        try await Self.installer(service).install(PushPairingFile(endpoint: Self.endpoint, key: key, muted: ["s-2", "s-1"]))

        let sent = try #require(service.messages(ofType: "push.install").first)
        #expect(sent["device_id"] as? String == Self.deviceID.rawValue)
        let pairing = try #require(sent["pairing"] as? [String: Any])
        #expect(pairing["endpoint"] as? String == Self.endpoint.absoluteString)
        #expect(pairing["key"] as? String == key.hex)
        #expect(pairing["muted"] as? [String] == ["s-1", "s-2"])
    }

    @Test("改靜音清單：送 push.update_muted(只帶靜音清單),不重送安裝、不送密鑰")
    func updatingMutedSendsOnlyMuted() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        try await Self.installer(service).install(PushPairingFile(endpoint: Self.endpoint, key: .generate(), muted: ["old"]))

        try await Self.installer(service).updateMuted(["s-2", "s-1"])

        let sent = try #require(service.messages(ofType: "push.update_muted").first)
        #expect(sent["device_id"] as? String == Self.deviceID.rawValue)
        #expect(sent["muted"] as? [String] == ["s-1", "s-2"])
        #expect(sent["pairing"] == nil)
        #expect(service.messages(ofType: "push.install").count == 1)
        #expect(service.pushState.pairings[Self.deviceID.rawValue] == ["s-1", "s-2"])
    }

    @Test("主機上沒有這支裝置的配對(被手動移除):改靜音清單丟 notPaired")
    func updatingMutedWithoutPairingIsNotPaired() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        await #expect(throws: PushPluginError.notPaired) { try await Self.installer(service).updateMuted(["s-1"]) }
    }

    @Test("push_plugin_failed 依操作對應：查狀態是 pluginListFailed、移除是 pluginUninstallFailed")
    func pluginFailureMapsPerOperation() async throws {
        var settings = FakeHostService.Settings(hostServiceVersion: "0.6.0")
        settings.pushStatusFailure = "herdr not running"
        settings.pushRemoveFailure = "uninstall failed"
        let service = try await Self.start(settings)
        defer { Task { await service.stop() } }
        let installer = Self.installer(service)
        // 移除外掛只發生在最後一支裝置、且外掛是 Purrdr 裝的。
        try await installer.install(PushPairingFile(endpoint: Self.endpoint, key: .generate()))

        await #expect(throws: PushPluginError.pluginListFailed("herdr not running")) { try await installer.status() }
        await #expect(throws: PushPluginError.pluginUninstallFailed("uninstall failed")) { try await installer.remove() }
    }

    @Test("唯讀裝置：查狀態可以，安裝丟 readOnlyDevice")
    func readOnlyDeviceCanOnlyReadStatus() async throws {
        var settings = FakeHostService.Settings(hostServiceVersion: "0.6.0")
        settings.validTokens.insert("token-read")
        settings.readOnlyTokens = ["token-read"]
        let service = try await Self.start(settings)
        defer { Task { await service.stop() } }
        let installer = Self.installer(service, token: "token-read")

        #expect(try await installer.status().isPaired == false)
        await #expect(throws: HostServiceError.readOnlyDevice) {
            try await installer.install(PushPairingFile(endpoint: Self.endpoint, key: .generate()))
        }
    }

    @Test("主機服務不回報安裝的使用者")
    func statusHasNoUser() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        #expect(try await Self.installer(service).status().user == nil)
    }
}
