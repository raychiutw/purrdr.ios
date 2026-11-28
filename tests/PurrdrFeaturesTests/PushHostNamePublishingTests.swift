import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrNotificationContent
import PurrdrTestSupport
import Testing

/// 主機名稱對應表(#431):app 把「配對雜湊 → 主機顯示名稱」寫到共用儲存(App Group),讓 Notification Service Extension 補副標題。
/// 主機改名、配對新增或移除、主機刪除時更新;對應表不含金鑰或權杖。
@MainActor
@Suite("推播主機名稱對應表")
struct PushHostNamePublishingTests {
    let sharing = RecordingHostNames()
    let pairings = InMemoryPushPairingStore()
    let studio = HostConfiguration(name: "Studio Mac", endpoint: SSHEndpoint(host: "studio-mac", username: "ray"))
    let build = HostConfiguration(name: "Build Box", endpoint: SSHEndpoint(host: "build-box", username: "ray"))
    let store = MemoryHostStore()

    func makeModel() -> HostsModel {
        store.hosts = [studio, build]
        let service = PushService(
            session: MemberSession(
                transport: URLSessionBackendTransport(baseURL: URL(string: "https://backend.test")!), tokenStore: InMemoryTokenStore()),
            platform: QuietPushPlatform(), store: pairings,
            device: PushDeviceIdentity(id: PushDeviceID(rawValue: "0123456789abcdef")!, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production,
                pluginSource: "raychiutw/purrdr.host/host-plugin"),
            hostNames: sharing, isSignedIn: { true })
        let model = HostsModel(store: store, demoChannel: FakeHost(), push: service, makeChannel: ChannelFactory().make)
        model.load()
        return model
    }

    @Test("第一個 frame 前不寫對應表,開閘後才寫一次且內容是最新的(#590)")
    func defersWritingUntilLaunchGateOpens() async throws {
        pairings.setKeyHash("hash-studio", forHost: studio.id.uuidString)
        let gate = LaunchGate()
        store.hosts = [studio, build]
        let service = PushService(
            session: MemberSession(
                transport: URLSessionBackendTransport(baseURL: URL(string: "https://backend.test")!), tokenStore: InMemoryTokenStore()),
            platform: QuietPushPlatform(), store: pairings,
            device: PushDeviceIdentity(id: PushDeviceID(rawValue: "0123456789abcdef")!, name: "iPhone", model: .iPhone),
            configuration: PushConfiguration(
                endpoint: URL(string: "https://backend.test/v1/push")!, environment: .production,
                pluginSource: "raychiutw/purrdr.host/host-plugin"),
            hostNames: sharing, isSignedIn: { true })
        service.launchGate = gate
        let model = HostsModel(store: store, demoChannel: FakeHost(), push: service, makeChannel: ChannelFactory().make)
        model.load()
        try model.rename(studio.id, to: "Studio 2")
        #expect(sharing.saved == [:])
        gate.open()
        for _ in 0..<200 where sharing.saved.isEmpty { await Task.yield() }
        #expect(sharing.saved == ["hash-studio": "Studio 2"])
    }

    @Test("已有配對的主機載入後,對應表有那組雜湊的名稱;沒有配對的主機不在裡面")
    func publishesPairedHostsOnLoad() {
        pairings.setKeyHash("hash-studio", forHost: studio.id.uuidString)
        let model = makeModel()
        #expect(sharing.saved == ["hash-studio": "Studio Mac"])
        #expect(model.hosts.count == 2)
    }

    @Test("主機改名後對應表跟著變")
    func renameUpdatesMap() throws {
        pairings.setKeyHash("hash-studio", forHost: studio.id.uuidString)
        let model = makeModel()

        try model.rename(studio.id, to: "Studio Pro")

        #expect(sharing.saved == ["hash-studio": "Studio Pro"])
    }

    @Test("新增配對後加進對應表,移除配對後拿掉")
    func pairingChangesUpdateMap() {
        let model = makeModel()
        #expect(sharing.saved.isEmpty)

        pairings.setKeyHash("hash-build", forHost: build.id.uuidString)
        #expect(sharing.saved == ["hash-build": "Build Box"])

        pairings.setKeyHash(nil, forHost: build.id.uuidString)
        #expect(sharing.saved.isEmpty)
        #expect(model.hosts.count == 2)
    }

    @Test("刪除主機後對應表拿掉那台")
    func deleteRemovesFromMap() async throws {
        pairings.setKeyHash("hash-studio", forHost: studio.id.uuidString)
        pairings.setKeyHash("hash-build", forHost: build.id.uuidString)
        let model = makeModel()
        #expect(sharing.saved.count == 2)

        try await model.delete(build.id)

        #expect(sharing.saved == ["hash-studio": "Studio Mac"])
    }

    @Test("登出清掉所有分區後對應表是空的")
    func clearingPartitionsEmptiesMap() {
        pairings.setKeyHash("hash-studio", forHost: studio.id.uuidString)
        let model = makeModel()
        #expect(sharing.saved == ["hash-studio": "Studio Mac"])

        pairings.removeAllPartitions()

        #expect(sharing.saved.isEmpty)
        #expect(model.hosts.count == 2)
    }
}

final class RecordingHostNames: PushHostNameSharing, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    var saved: [String: String] { lock.withLock { names } }
    func save(_ names: [String: String]) { lock.withLock { self.names = names } }
    func load() -> [String: String] { saved }
}

private final class QuietPushPlatform: PushPlatform {
    func authorization() async -> PushAuthorization { .notDetermined }
    func requestAuthorization() async -> Bool { false }
    func deviceToken() async throws -> Data { throw CancellationError() }
    func openSettings() {}
}
