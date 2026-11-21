import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import Security
import Synchronization

/// HTTPS 主機(主機服務，ADR-0010)要用的東西：裝置權杖、連線配對與主機連線的建立方式。
public struct HostServiceAccess {
    public let tokens: any DeviceTokenStore
    public let pairing: HostServicePairing
    /// 顯示在主機裝置列表的名稱。
    public let deviceName: String
    /// 依位址與權杖來源建立主機連線(權杖在撥號時才讀)。
    public let makeConnection: @MainActor (HostServiceAddress, @escaping @Sendable () throws -> String?) -> any HostConnection

    public init(
        tokens: any DeviceTokenStore = InMemoryDeviceTokenStore(), pairing: HostServicePairing = HostServicePairing(),
        deviceName: String = "iPhone",
        makeConnection: @escaping @MainActor (HostServiceAddress, @escaping @Sendable () throws -> String?) -> any HostConnection = {
            HTTPSHostConnection(address: $0, deviceToken: $1)
        }
    ) {
        self.tokens = tokens
        self.pairing = pairing
        self.deviceName = deviceName
        self.makeConnection = makeConnection
    }

    /// 不等待地請主機服務撤銷這個權杖(失敗也不影響：主機離線時可在主機上撤銷)。
    func revokeWithoutWaiting(_ deviceToken: String, at address: HostServiceAddress) {
        let pairing = pairing
        Task { try? await pairing.revoke(address: address, deviceToken: deviceToken) }
    }

    /// 已存的 HTTPS 主機的連線。
    @MainActor
    func connection(for host: HostConfiguration, address: HostServiceAddress) -> any HostConnection {
        let tokens = tokens
        let id = host.id
        return makeConnection(address) { try tokens.deviceToken(for: id) }
    }
}

/// 裝置權杖存 Keychain:每台主機一個 generic password 項目，與主機設定、SSH 祕密分開。
/// 可存取等級「解鎖時、僅此裝置」,不經 iCloud 同步(GLOSSARY「裝置權杖」)。
public struct KeychainDeviceTokenStore: DeviceTokenStore {
    private let keychain: any KeychainAPI
    private let service: String

    public init(keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr.device-token") {
        self.keychain = keychain
        self.service = service
    }

    public func deviceToken(for host: UUID) throws -> String? {
        var query = itemQuery(host)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setDeviceToken(_ token: String?, for host: UUID) throws {
        guard let token else {
            let status = keychain.delete(itemQuery(host))
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(token.utf8)
        var attributes = itemQuery(host)
        attributes[kSecValueData as String] = data
        // 可存取等級只能在新增項目時設定。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Purrdr device token"
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            let updated = keychain.update(itemQuery(host), [kSecValueData as String: data])
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func itemQuery(_ host: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// HTTPS 主機沒有主機通道：只有 SSH 才有的功能(登入 Shell、檔案、推播外掛、主題…)一律以 `unsupported` 失敗，不連網路。
struct UnsupportedHostChannel: HostChannel {
    func execute(_ command: String) async throws -> any ExecSession {
        throw HostServiceError.unsupported("ssh")
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw HostServiceError.unsupported("ssh")
    }
}

extension HostServiceAccess {
    /// 正式 app:權杖存 Keychain,連線經 `URLSession`(系統 TLS)。
    public static func system(deviceName: String, appVersion: String?) -> HostServiceAccess {
        HostServiceAccess(tokens: KeychainDeviceTokenStore(), deviceName: deviceName) {
            HTTPSHostConnection(address: $0, deviceToken: $1, appVersion: appVersion)
        }
    }

    /// UI 測試：不連網路、權杖只在記憶體。配對碼 `K7QM-2XPA` 換得權杖、`R3AD-0NLY` 換得唯讀權杖、`OLD0-CODE` 過期、其他不對;
    /// HTTPS 主機的連線是包住 `channel`(Demo 主機)的主機連線，畫面看到 Demo 的 Agent。
    /// - Parameters:
    ///   - hostServiceVersion: 連線回報的主機服務版本(UI 測試旗標 `-demoOutdatedHostService` 給舊版，#198)。
    ///   - pairedHosts: 啟動時已配對好的主機。
    ///   - readOnlyHosts: 啟動時已用唯讀權杖配對好的主機。
    public static func uiTesting(
        channel: any HostChannel, hostServiceVersion: String = HostServiceUpdates.latestKnownVersion, pairedHosts: [UUID] = [],
        readOnlyHosts: [UUID] = []
    ) -> HostServiceAccess {
        let seededTokens = pairedHosts.map { ($0, UITestingHostServiceConnection.token) }
            + readOnlyHosts.map { ($0, UITestingHostServiceConnection.readOnlyToken) }
        let tokens = InMemoryDeviceTokenStore(tokens: Dictionary(seededTokens, uniquingKeysWith: { _, readOnly in readOnly }))
        let pairing = HostServicePairing(http: UITestingHostServiceHTTP())
        return HostServiceAccess(tokens: tokens, pairing: pairing, deviceName: "iPhone") { _, deviceToken in
            UITestingHostServiceConnection(
                base: SSHHostConnection(channel: channel), channel: channel, deviceToken: deviceToken,
                hostService: UITestingHostServiceState(installedVersion: hostServiceVersion))
        }
    }
}

/// UI 測試的配對與撤銷：照協定回應，不連網路。
private struct UITestingHostServiceHTTP: HostServiceHTTPSending {
    func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse {
        if url.path() == "/v1/revoke" { return HostServiceHTTPResponse(status: 204, body: Data()) }
        let code = body.flatMap { try? JSONDecoder().decode(HostServiceProtocol.PairRequest.self, from: $0) }?.pairingCode
        switch code?.uppercased() {
        case "K7QM-2XPA":
            let paired = HostServiceProtocol.PairResponse(deviceId: "ui-testing", deviceToken: UITestingHostServiceConnection.token, readOnly: false)
            return HostServiceHTTPResponse(status: 200, body: try JSONEncoder().encode(paired))
        case UITestingHostServiceConnection.readOnlyPairingCode:
            let paired = HostServiceProtocol.PairResponse(
                deviceId: "ui-testing-read-only", deviceToken: UITestingHostServiceConnection.readOnlyToken, readOnly: true)
            return HostServiceHTTPResponse(status: 200, body: try JSONEncoder().encode(paired))
        case "OLD0-CODE":
            return try Self.error(.pairingCodeExpired)
        default:
            return try Self.error(.pairingCodeInvalid)
        }
    }

    private static func error(_ code: HostServiceProtocol.ErrorCode) throws -> HostServiceHTTPResponse {
        let message = HostServiceProtocol.ServerMessage.errorMessage(.init(code: code, message: code.rawValue))
        return HostServiceHTTPResponse(status: 401, body: try JSONEncoder().encode(message))
    }
}

/// UI 測試的 HTTPS 主機連線：轉給 Demo 主機;唯讀權杖時像主機服務一樣回報唯讀並拒絕寫入類操作。
private struct UITestingHostServiceConnection: HostConnection {
    static let token = "ui-testing-token"
    static let readOnlyPairingCode = "R3AD-0NLY"
    static let readOnlyToken = "ui-testing-read-only-token"

    let base: any HostConnection
    /// Demo 主機的通道：推播外掛安裝在它的記憶體裡回應(#295,配對後通知開關能點)。
    let channel: any HostChannel
    let deviceToken: @Sendable () throws -> String?
    let hostService: UITestingHostServiceState
    /// 主機端的 Send When Done 佇列(#305):在記憶體裡。
    let sendWhenDoneState = UITestingSendWhenDoneHost()

    func hostServiceVersion() async throws -> String? { hostService.installedVersion }

    func isReadOnlyDevice() async throws -> Bool {
        try deviceToken() == Self.readOnlyToken
    }

    func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
        // 寫入與否照協定(schema 的 x-write),與主機服務相同。
        if (try? HTTPSHostConnection.isWriteRequest(request)) == true, try await isReadOnlyDevice() {
            throw HostServiceError.readOnlyDevice
        }
        return try await base.herdrRequest(request, deadline: deadline)
    }

    func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
        try await base.herdrEvents(request)
    }

    func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        try await base.readTranscript(request)
    }

    func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        try await base.openPaneTerminal(target: target, columns: columns, rows: rows, takeover: takeover)
    }

    func disconnect() async {
        await base.disconnect()
    }
}

/// UI 測試的 Send When Done(#305):佇列在記憶體,不會自己送出;唯讀權杖停用。
extension UITestingHostServiceConnection: SendWhenDoneHosting {
    func sendWhenDoneAvailability() async -> SendWhenDoneAvailability {
        (try? await isReadOnlyDevice()) == true ? .readOnlyDevice : .available
    }

    func sendWhenDoneQueues() async throws -> [SendWhenDoneQueue] { await sendWhenDoneState.queues() }

    func sendWhenDoneAdd(paneID: String, text: String, expectedSession: String) async throws -> String {
        try await sendWhenDoneState.add(paneID: paneID, text: text, expectedSession: expectedSession)
    }

    func sendWhenDoneRemove(paneID: String, itemID: String) async throws {
        try await sendWhenDoneState.remove(paneID: paneID, itemID: itemID)
    }

    func sendWhenDoneReorder(paneID: String, itemIDs: [String]) async throws {
        try await sendWhenDoneState.reorder(paneID: paneID, itemIDs: itemIDs)
    }

    func sendWhenDoneChanges() async throws -> AsyncThrowingStream<SendWhenDoneChange, any Error> {
        await sendWhenDoneState.changes()
    }
}

/// UI 測試的主機端佇列:記憶體裡的佇列,每次變動推給訂閱者(同主機服務的 `queue.changed`)。
actor UITestingSendWhenDoneHost {
    private var queueByPane: [String: SendWhenDoneQueue] = [:]
    private var observers: [AsyncThrowingStream<SendWhenDoneChange, any Error>.Continuation] = []
    private var nextItem = 0

    func queues() -> [SendWhenDoneQueue] { Array(queueByPane.values) }

    func add(paneID: String, text: String, expectedSession: String) throws -> String {
        nextItem += 1
        let item = SendWhenDoneItem(id: "ui-q\(nextItem)", text: text, expectedSession: expectedSession)
        var queue = queueByPane[paneID] ?? SendWhenDoneQueue(paneID: paneID, items: [])
        queue.items.append(item)
        publish(queue)
        return item.id
    }

    func remove(paneID: String, itemID: String) throws {
        guard var queue = queueByPane[paneID], queue.items.contains(where: { $0.id == itemID }) else {
            throw HostServiceError.queueItemUnknown
        }
        queue.items.removeAll { $0.id == itemID }
        publish(queue)
    }

    /// 與主機服務相同:識別碼必須恰好是目前佇列的所有識別碼。
    func reorder(paneID: String, itemIDs: [String]) throws {
        guard var queue = queueByPane[paneID], Set(queue.items.map(\.id)) == Set(itemIDs), queue.items.count == itemIDs.count else {
            throw HostServiceError.queueItemUnknown
        }
        queue.items = itemIDs.compactMap { id in queue.items.first { $0.id == id } }
        publish(queue)
    }

    func changes() -> AsyncThrowingStream<SendWhenDoneChange, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SendWhenDoneChange, any Error>.makeStream()
        observers.append(continuation)
        return stream
    }

    private func publish(_ queue: SendWhenDoneQueue) {
        queueByPane[queue.paneID] = queue
        for observer in observers { observer.yield(SendWhenDoneChange(queue: queue)) }
    }
}

/// UI 測試的推播外掛安裝：主機服務代裝的替身，由 Demo 主機在記憶體回應(來源字串不影響 Demo 主機)。
extension UITestingHostServiceConnection: PushPluginInstallerProviding {
    func pushPluginInstallers() -> (@Sendable (PushDeviceID) -> any PushPluginInstalling)? {
        let channel = channel
        return { SSHPushPluginInstaller(channel: channel, herdr: HerdrInstallation(), deviceID: $0, pluginSource: "ui-testing/host-plugin") }
    }
}

/// UI 測試的主機服務管理(#290):有新版 `latestVersion`;立即更新後重新連線就是新版。唯讀權杖的寫入被拒。
extension UITestingHostServiceConnection: HostServiceManaging {
    func hostServiceUpdateStatus() async throws -> HostServiceUpdateStatus {
        hostService.status
    }

    func updateHostService() async throws -> HostServiceUpdateStart {
        if try await isReadOnlyDevice() { throw HostServiceError.readOnlyDevice }
        let status = hostService.status
        guard status.updateAvailable else { return .upToDate(version: status.installedVersion) }
        return .started(from: status.installedVersion, to: UITestingHostServiceState.latestVersion)
    }

    func setHostServiceAutoUpdate(_ enabled: Bool) async throws -> Bool {
        if try await isReadOnlyDevice() { throw HostServiceError.readOnlyDevice }
        return hostService.setAutoUpdate(enabled)
    }

    func reconnectForHostServiceVersion() async throws -> String? {
        hostService.finishUpdate()
    }
}

/// UI 測試主機服務的版本、自動更新開關與撤銷過的裝置(每台主機一份)。
final class UITestingHostServiceState: Sendable {
    static let latest = HostServiceVersion(0, 7, 1)
    static var latestVersion: String { latest.description }

    private let state: Mutex<(installed: String, autoUpdate: Bool)>
    private let revokedDevices = Mutex<Set<String>>([])

    init(installedVersion: String) {
        state = Mutex((installedVersion, true))
    }

    var revoked: Set<String> { revokedDevices.withLock { $0 } }

    func revoke(_ id: String) {
        revokedDevices.withLock { _ = $0.insert(id) }
    }

    var installedVersion: String { state.withLock { $0.installed } }

    var status: HostServiceUpdateStatus {
        state.withLock { current in
            let available = HostServiceVersion(current.installed).map { $0 < Self.latest } ?? false
            return HostServiceUpdateStatus(
                installedVersion: current.installed, latestVersion: Self.latestVersion, updateAvailable: available,
                autoUpdate: current.autoUpdate,
                lastUpdate: HostServiceLastUpdate(checkedAtText: "2026-11-20T08:00:00Z", result: "up to date"))
        }
    }

    func setAutoUpdate(_ enabled: Bool) -> Bool {
        state.withLock {
            $0.autoUpdate = enabled
            return enabled
        }
    }

    /// 立即更新後重新連線：換成新版。
    func finishUpdate() -> String {
        state.withLock {
            $0.installed = Self.latestVersion
            return $0.installed
        }
    }
}

/// UI 測試的已配對裝置(#291):這支 iPhone 與另一支唯讀的 iPad;撤銷後從列表拿掉，唯讀權杖的撤銷被拒。
extension UITestingHostServiceConnection: PairedDevicesManaging {
    func pairedDevices() async throws -> [PairedDeviceRecord] {
        let revoked = hostService.revoked
        let thisDevice = PairedDeviceRecord(
            id: "ui-testing", name: "iPhone", isReadOnly: try await isReadOnlyDevice(),
            pairedAt: Date(timeIntervalSince1970: 1_793_521_800), isCurrentDevice: true)
        let otherDevice = PairedDeviceRecord(
            id: "ui-testing-ipad", name: "iPad", isReadOnly: true, pairedAt: Date(timeIntervalSince1970: 1_794_312_005),
            isCurrentDevice: false)
        return [thisDevice, otherDevice].filter { !revoked.contains($0.id) }
    }

    func revokePairedDevice(_ id: String) async throws {
        if try await isReadOnlyDevice() { throw HostServiceError.readOnlyDevice }
        hostService.revoke(id)
    }
}
