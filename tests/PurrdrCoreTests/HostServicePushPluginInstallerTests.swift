import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的推播外掛安裝(#265):經主機服務的 `push.status`／`push.install`／`push.remove`(0.6.0 起)。
@Suite("主機服務的推播外掛安裝")
struct HostServicePushPluginInstallerTests {
    static let endpoint = URL(string: "https://backend.test/v1/push")!
    static let deviceID = "aaaaaaaaaaaaaaaa"

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
        #expect(sent["device_id"] as? String == Self.deviceID)
        let pairing = try #require(sent["pairing"] as? [String: Any])
        #expect(pairing["endpoint"] as? String == Self.endpoint.absoluteString)
        #expect(pairing["key"] as? String == key.hex)
        #expect(pairing["muted"] as? [String] == ["s-1", "s-2"])
    }

    @Test("改靜音清單：以同一組配對重送安裝，只換靜音清單")
    func updatingMutedResendsThePairing() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let installer = Self.installer(service)
        let key = PushPairingKey.generate()
        try await installer.install(PushPairingFile(endpoint: Self.endpoint, key: key, muted: ["old"]))

        try await installer.updateMuted(["new"])

        let resent = try #require(service.messages(ofType: "push.install").last?["pairing"] as? [String: Any])
        #expect(resent["key"] as? String == key.hex)
        #expect(service.pushState.pairings[Self.deviceID] == ["new"])
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
