import Foundation
import Observation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

/// 通知權限(只讀現況時不跳系統對話框)。「暫時授權」視為已授權(行為規格 F14)。
public enum PushAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// 通知權限與 APNs device token(Seam 3:正式是 `SystemPushPlatform`,測試用假的)。
@MainActor
public protocol PushPlatform: AnyObject {
    /// 目前的權限;不會跳系統對話框。
    func authorization() async -> PushAuthorization
    /// 請求權限(會跳系統對話框)。只在使用者打開推播開關時呼叫。
    func requestAuthorization() async -> Bool
    /// 向 APNs 註冊並取得 device token。
    func deviceToken() async throws -> Data
    /// 打開 iOS 設定裡這個 app 的頁面(權限被拒時)。
    func openSettings()
}

/// 這支裝置的推播配對紀錄：裝置 id、每台主機的配對密鑰**雜湊**(不存密鑰)、上次註冊的 device token。
@MainActor
public protocol PushPairingStore: AnyObject {
    /// 16 位 hex 亂數，首次產生後持久化(拼進主機路徑 `~/.purrdr/push-<id>/`,行為規格 F14)。
    var deviceID: String { get }
    var lastDeviceToken: String? { get set }
    /// 配對上次以哪個裝置 id 向後台註冊(#266);舊版 app 註冊的是 `nil`,啟動時帶裝置欄位重新註冊。
    var registeredDeviceID: String? { get set }
    func keyHash(forHost host: String) -> String?
    func host(forKeyHash keyHash: String) -> String?
    func setKeyHash(_ keyHash: String?, forHost host: String)
    /// 所有配對(主機 id → 雜湊)。
    var pairings: [String: String] { get }
}

extension PushPairingStore {
    public func host(forKeyHash keyHash: String) -> String? {
        pairings.first { $0.value == keyHash }?.key
    }

    public func keyHash(forHost host: String) -> String? { pairings[host] }

    public static func newDeviceID() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// 只在記憶體的紀錄(測試、UI 測試)。
@MainActor
public final class InMemoryPushPairingStore: PushPairingStore {
    public let deviceID: String
    public var lastDeviceToken: String?
    public var registeredDeviceID: String?
    public private(set) var pairings: [String: String] = [:]

    public init(deviceID: String = InMemoryPushPairingStore.newDeviceID()) {
        self.deviceID = deviceID
    }

    public func setKeyHash(_ keyHash: String?, forHost host: String) { pairings[host] = keyHash }
}

/// 存在 `UserDefaults` 的紀錄(只在這支裝置，不同步;雜湊不是祕密)。
@MainActor
public final class UserDefaultsPushPairingStore: PushPairingStore {
    private let defaults: UserDefaults
    static let deviceIDKey = "push.deviceID"
    static let pairingsKey = "push.pairings"
    static let tokenKey = "push.lastDeviceToken"
    static let registeredDeviceIDKey = "push.registeredDeviceID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var deviceID: String {
        if let id = defaults.string(forKey: Self.deviceIDKey), SSHPushPluginInstaller.isValidDeviceID(id) { return id }
        let id = Self.newDeviceID()
        defaults.set(id, forKey: Self.deviceIDKey)
        return id
    }

    public var lastDeviceToken: String? {
        get { defaults.string(forKey: Self.tokenKey) }
        set { defaults.set(newValue, forKey: Self.tokenKey) }
    }

    public var registeredDeviceID: String? {
        get { defaults.string(forKey: Self.registeredDeviceIDKey) }
        set { defaults.set(newValue, forKey: Self.registeredDeviceIDKey) }
    }

    public var pairings: [String: String] {
        defaults.dictionary(forKey: Self.pairingsKey) as? [String: String] ?? [:]
    }

    public func setKeyHash(_ keyHash: String?, forHost host: String) {
        var pairings = pairings
        pairings[host] = keyHash
        defaults.set(pairings, forKey: Self.pairingsKey)
    }
}

/// 推播的設定(composition root 提供)。
public struct PushConfiguration: Sendable {
    /// 主機外掛呼叫的後台網址(`<後台>/v1/push`),寫進主機上的配對檔。
    public var endpoint: URL
    public var environment: MemberSession.PushEnvironment
    /// `herdr plugin install` 的來源(公開 repo `owner/repo`)。
    public var pluginSource: String

    public init(endpoint: URL, environment: MemberSession.PushEnvironment, pluginSource: String) {
        self.endpoint = endpoint
        self.environment = environment
        self.pluginSource = pluginSource
    }
}

/// 推播的共用部分：後台、權限與 token、配對紀錄。每台主機的開關是 `PushModel`。
@MainActor
public final class PushService {
    let session: MemberSession
    let platform: any PushPlatform
    public let store: any PushPairingStore
    /// 這支裝置(註冊配對時帶給後台，「通知裝置」以它標出這支)。
    public let device: PushDeviceIdentity
    let configuration: PushConfiguration
    let isPlusActive: @MainActor () async -> Bool
    private var models: [WeakPushModel] = []

    /// - Parameters:
    ///   - device: 這支裝置的 id(Keychain 的 UUID)、預設名稱與型號。
    ///   - isPlusActive: 會員現在有沒有 Purrdr Plus(`SubscriptionModel` 重讀後台後的 `isPlusActive`)。
    public init(
        session: MemberSession, platform: any PushPlatform, store: any PushPairingStore, device: PushDeviceIdentity,
        configuration: PushConfiguration, isPlusActive: @escaping @MainActor () async -> Bool
    ) {
        self.session = session
        self.platform = platform
        self.store = store
        self.device = device
        self.configuration = configuration
        self.isPlusActive = isPlusActive
    }

    /// 每次啟動：有配對時取 token(不請求權限),跟上次不同(APNs token 輪替)或還沒帶裝置 id 註冊過(舊版 app)
    /// 就對每組配對向後台重新註冊。主機上的配對檔只有密鑰，不必改。盡力而為，失敗下次啟動再試。
    public func refreshRegistrations() async {
        let pairings = store.pairings
        guard !pairings.isEmpty, await platform.authorization() == .authorized,
              let token = try? await platform.deviceToken() else { return }
        let hex = Self.hex(token)
        guard hex != store.lastDeviceToken || store.registeredDeviceID != device.id else { return }
        var allSucceeded = true
        for keyHash in pairings.values.sorted() {
            do {
                try await session.registerPushPairing(
                    keyHash: keyHash, deviceToken: hex, environment: configuration.environment, device: device)
            } catch {
                allSucceeded = false
            }
        }
        if allSucceeded {
            store.lastDeviceToken = hex
            store.registeredDeviceID = device.id
        }
    }

    /// 啟動時：這支裝置已不在後台的「通知裝置」(被別支裝置關閉)就清掉本機的配對，「通知」區塊回到關閉。
    /// 讀不到清單(離線、沒有訂閱)或配對還沒帶裝置 id 註冊時不判斷。
    public func reconcileRemoteRevocation() async {
        guard !store.pairings.isEmpty, store.registeredDeviceID == device.id,
              let devices = try? await session.pushDevices(currentDeviceID: device.id) else { return }
        reconcile(with: devices)
    }

    /// 清單裡沒有這支裝置時清掉本機的配對。
    func reconcile(with devices: [PushDevice]) {
        guard !store.pairings.isEmpty, store.registeredDeviceID == device.id,
              !devices.contains(where: { $0.isCurrent || $0.id == device.id }) else { return }
        forgetAllPairings()
    }

    /// 這支裝置的後台配對已全部撤銷：清掉本機紀錄，主機上的殘留配對由外掛收到 410 時清掉。
    func forgetAllPairings() {
        for host in store.pairings.keys {
            store.setKeyHash(nil, forHost: host)
        }
        models.removeAll { $0.model == nil }
        for entry in models {
            entry.model?.pairingRevoked()
        }
    }

    func track(_ model: PushModel) {
        models.removeAll { $0.model == nil }
        models.append(WeakPushModel(model: model))
    }

    /// 移除主機時：不等待地刪掉那台主機上的配對並撤銷(行為規格 F14)。刪完配對後呼叫 `afterRemoving`(例如關閉為此另開的連線)。
    public func forget(
        hostID: String, installer: any PushPluginInstalling, afterRemoving: @escaping @Sendable () async -> Void = {}
    ) {
        guard let keyHash = store.keyHash(forHost: hostID) else { return }
        store.setKeyHash(nil, forHost: hostID)
        let session = session
        Task {
            try? await installer.remove()
            await afterRemoving()
            try? await session.revokePushPairing(keyHash: keyHash)
        }
    }

    /// 這支裝置經主機服務(HTTPS 主機)的推播外掛安裝。
    public func hostServiceInstaller(connection: HTTPSHostConnection) -> any PushPluginInstalling {
        HostServicePushPluginInstaller(connection: connection, deviceID: store.deviceID)
    }

    /// 這支裝置經 SSH 的推播外掛安裝。
    public func sshInstaller(channel: any HostChannel, herdr: HerdrInstallation) -> any PushPluginInstalling {
        SSHPushPluginInstaller(channel: channel, herdr: herdr, deviceID: store.deviceID, pluginSource: configuration.pluginSource)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

@MainActor
private final class WeakPushModel {
    weak var model: PushModel?

    init(model: PushModel) {
        self.model = model
    }
}

/// 一台主機的推播開關(行為規格 F14、ADR-0004)。
///
/// 打開：Purrdr Plus → 通知權限(只有這裡會跳系統對話框)→ APNs token → 檢查主機並請使用者確認(以哪個使用者安裝)
/// → 產生配對密鑰、向後台註冊雜湊 → 經推播外掛安裝寫配對並安裝主機外掛。主機失敗就撤銷剛註冊的配對。
/// 關閉：移除主機上這支裝置的配對(最後一支裝置時連外掛)→ 撤銷這支裝置的後台配對。
@MainActor
@Observable
public final class PushModel {
    public enum State: Equatable {
        case off
        case checking
        /// 等使用者確認：會以 `user` 在主機上安裝外掛(主機服務不回報使用者，是 `nil`)。
        case confirming(user: String?)
        case turningOn
        case on
        case turningOff
    }

    public enum Problem: Equatable {
        /// Demo 主機不能推播。
        case demoHost
        /// 需要 Purrdr Plus(或已到期)。
        case needsSubscription
        /// 通知權限被拒：到 iOS 設定打開。
        case permissionDenied
        /// 取不到 APNs token(模擬器、缺 entitlement);附原始錯誤。
        case unsupportedDevice(String)
        /// 主機服務太舊，不能代裝外掛：附依已安裝版本的更新指令。
        case hostServiceOutdated(HostServiceUpdateCommands)
        case failed(String)
    }

    public private(set) var state: State = .off
    public var problem: Problem?
    /// 這台主機上另外幾支裝置開著通知(上次查狀態的結果;不列出是哪些裝置)。
    public private(set) var otherDevices = 0
    /// 上次查狀態時主機外掛已裝(別的裝置或使用者裝的):開啟只新增這支裝置的配對。
    public private(set) var pluginAlreadyInstalled = false

    private let service: PushService?
    private let hostID: String?
    private let installer: (any PushPluginInstalling)?
    private let muted: @MainActor () -> Set<String>
    private var deviceToken: Data?

    /// - Parameters:
    ///   - service: `nil` 時這個 app 沒有推播(例如 UI 測試以外沒設定)。
    ///   - hostID: 主機 id;Demo 主機是 `nil`。
    ///   - installer: 這支裝置在這台主機的推播外掛安裝;`nil` 時這台主機沒有推播。
    ///   - muted: 目前靜音的聊天(session 值),配對時寫進主機。
    public init(service: PushService?, hostID: String?, installer: (any PushPluginInstalling)?,
                muted: @escaping @MainActor () -> Set<String>) {
        self.service = service
        self.hostID = hostID
        self.installer = installer
        self.muted = muted
        if let hostID, service?.store.keyHash(forHost: hostID) != nil { state = .on }
        service?.track(self)
    }

    /// 這支裝置被遠端關閉(配對已撤銷):回到關閉。
    func pairingRevoked() {
        if state == .on { state = .off }
    }

    public var isAvailable: Bool { service != nil && installer != nil }

    /// 使用者打開開關。
    public func requestOn() async {
        guard state == .off, let service, let installer else { return }
        problem = nil
        guard hostID != nil else {
            problem = .demoHost
            return
        }
        state = .checking
        guard await service.isPlusActive() else { return stop(.needsSubscription) }
        switch await service.platform.authorization() {
        case .authorized:
            break
        case .denied:
            return stop(.permissionDenied)
        case .notDetermined:
            guard await service.platform.requestAuthorization() else { return stop(.permissionDenied) }
        }
        do {
            deviceToken = try await service.platform.deviceToken()
        } catch {
            return stop(.unsupportedDevice(error.localizedDescription))
        }
        do {
            let status = try await installer.status()
            record(status)
            state = .confirming(user: status.user)
        } catch {
            stop(Self.problem(for: error))
        }
    }

    public func cancel() {
        if case .confirming = state { state = .off }
    }

    /// 使用者確認安裝。
    public func confirm() async {
        guard case .confirming = state, let service, let installer, let hostID, let deviceToken else { return }
        state = .turningOn
        let key = PushPairingKey.generate()
        // 已有其他配對時，它們是否帶裝置 id 註冊過仍由啟動時的重新註冊決定。
        let isFirstPairing = service.store.pairings.isEmpty
        do {
            try await service.session.registerPushPairing(
                keyHash: key.hash, deviceToken: PushService.hex(deviceToken), environment: service.configuration.environment,
                device: service.device)
        } catch BackendError.backend(_, "subscription_required", _) {
            return stop(.needsSubscription)
        } catch BackendError.signedOut {
            return stop(.needsSubscription)
        } catch {
            return stop(.failed(Self.describe(error)))
        }
        do {
            let file = PushPairingFile(endpoint: service.configuration.endpoint, key: key, muted: muted())
            try await installer.install(file)
        } catch {
            try? await service.session.revokePushPairing(keyHash: key.hash)
            return stop(Self.problem(for: error))
        }
        service.store.setKeyHash(key.hash, forHost: hostID)
        service.store.lastDeviceToken = PushService.hex(deviceToken)
        if isFirstPairing { service.store.registeredDeviceID = service.device.id }
        state = .on
    }

    /// 使用者關閉開關：移除主機上這支裝置的配對(最後一支才連外掛),撤銷後台配對。主機連不上時維持開啟並說明。
    public func turnOff() async {
        guard state == .on, let service, let installer, let hostID else { return }
        problem = nil
        state = .turningOff
        do {
            try await installer.remove()
        } catch PushPluginError.pluginUninstallFailed(let message) {
            // 配對已移除(外掛沒有配對就什麼都不送),當成已關閉並說明。
            problem = .failed(String(localized: "Notifications are off, but herdr couldn’t remove the Purrdr plugin: \(message)"))
        } catch {
            state = .on
            problem = Self.problem(for: error)
            return
        }
        if let keyHash = service.store.keyHash(forHost: hostID) {
            // 主機上已沒有密鑰，撤銷失敗也不會再有推播。
            try? await service.session.revokePushPairing(keyHash: keyHash)
        }
        service.store.setKeyHash(nil, forHost: hostID)
        state = .off
    }

    /// 查這台主機的推播狀態(另有幾支裝置開著)。查不到就維持上次的結果，不顯示錯誤。
    public func refreshStatus() async {
        guard let installer, hostID != nil, let status = try? await installer.status() else { return }
        record(status)
    }

    private func record(_ status: PushPluginStatus) {
        otherDevices = status.otherPairedDevices
        pluginAlreadyInstalled = status.pluginInstalled
    }

    /// 靜音清單改了：推播開著時改寫主機上的配對檔(iOS 在 app 能攔截前就顯示推播，靜音只能在主機端生效)。
    public func syncMuted(_ muted: Set<String>) async {
        guard state == .on, let installer else { return }
        try? await installer.updateMuted(muted)
    }

    public func openSystemSettings() {
        service?.platform.openSettings()
    }

    private func stop(_ problem: Problem) {
        state = .off
        self.problem = problem
    }

    static func problem(for error: any Error) -> Problem {
        if case PushPluginError.hostServiceOutdated(let installed) = error {
            return .hostServiceOutdated(HostServiceUpdates.commands(installed: installed))
        }
        return .failed(describe(error))
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case PushPluginError.pluginInstallFailed(let message):
            String(localized: "herdr couldn’t install the Purrdr plugin: \(message)")
        case PushPluginError.pluginListFailed(let message):
            String(localized: "Couldn’t ask herdr about plugins. Make sure herdr is running on the host. \(message)")
        case HostServiceError.readOnlyDevice:
            String(localized: "This device is paired read-only with the host service, so it can’t turn on notifications there.")
        case BackendError.unreachable:
            String(localized: "Couldn’t reach Purrdr’s server. Check your connection and try again.")
        default:
            String(localized: "Couldn’t turn on notifications: \(error.localizedDescription)")
        }
    }
}

/// 點通知時要開的 Agent:payload 根層的 `pairing`(配對密鑰雜湊 → 主機)與 `pane`(後台組的,`raychiutw/purrdr.server` 的 `src/push.ts`)。
public struct PushRoute: Equatable, Sendable {
    public var keyHash: String
    public var paneID: String?

    public init(keyHash: String, paneID: String?) {
        self.keyHash = keyHash
        self.paneID = paneID
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let keyHash = userInfo["pairing"] as? String, !keyHash.isEmpty else { return nil }
        self.init(keyHash: keyHash, paneID: userInfo["pane"] as? String)
    }
}

/// 點了推播通知 → 等畫面處理(`TopNavigationView` 收起 sheet、切換主機、開聊天)。
///
/// 以通知的 request id 去重：冷啟動時同一則通知可能送來兩次(行為規格 F14)。
@MainActor
@Observable
public final class PushNotificationRouter {
    /// 還沒處理的點擊;畫面處理完設回 `nil`。
    public var pending: PushRoute?
    @ObservationIgnored private var handled: Set<String> = []

    public init() {}

    public func receive(_ route: PushRoute, requestID: String) {
        guard handled.insert(requestID).inserted else { return }
        pending = route
    }
}
