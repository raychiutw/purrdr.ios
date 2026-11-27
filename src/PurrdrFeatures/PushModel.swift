import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrNotificationContent

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

/// 這支裝置的推播配對紀錄：每台主機的配對密鑰**雜湊**(不存密鑰)與每組配對上次以哪個 device token 註冊。
@MainActor
public protocol PushPairingStore: AnyObject {
    func keyHash(forHost host: String) -> String?
    func host(forKeyHash keyHash: String) -> String?
    /// 設成 `nil` 時一併清掉那組配對的註冊紀錄。
    func setKeyHash(_ keyHash: String?, forHost host: String)
    /// 所有配對(主機 id → 雜湊)。
    var pairings: [String: String] { get }
    /// 帶裝置 id 向後台註冊成功的配對(雜湊 → 當時的 device token);舊版 app 註冊的配對不在裡面。
    var registeredTokens: [String: String] { get }
    func setRegisteredToken(_ token: String?, forKeyHash keyHash: String)
    /// 這組配對要收的推播種類;沒記過(舊版 app 開的)是 `nil`。
    func kinds(forKeyHash keyHash: String) -> Set<PushKind>?
    func setKinds(_ kinds: Set<PushKind>?, forKeyHash keyHash: String)
    /// 清除某個會員的分區(登出、刪除會員或換會員時,#405)。
    func removePartition(of memberID: String)
    /// 清除所有會員的分區(登入已失效或冷啟動時沒有會員)。
    func removeAllPartitions()
    /// 合併後留下的是另一個會員(#410):把舊會員分區的紀錄搬到新會員,舊的不留(後台的配對已跟著歸新會員)。
    func movePartition(from oldID: String, to newID: String)
    /// 配對有增減或分區被清除後呼叫(主機名稱對應表跟著更新,#431);`PushService` 建立時接上。
    var onPairingsChanged: (@MainActor () -> Void)? { get set }
}

extension PushPairingStore {
    public func host(forKeyHash keyHash: String) -> String? {
        pairings.first { $0.value == keyHash }?.key
    }

    public func keyHash(forHost host: String) -> String? { pairings[host] }
}

/// 只在記憶體的紀錄(測試、UI 測試)。依會員分區(#405):沒有會員時讀到空的、寫入不留下。
@MainActor
public final class InMemoryPushPairingStore: PushPairingStore {
    private struct Records {
        var pairings: [String: String] = [:]
        var registeredTokens: [String: String] = [:]
        var kinds: [String: Set<PushKind>] = [:]
    }

    private let partition: MemberPartition
    private var partitions: [String: Records] = [:]
    public var onPairingsChanged: (@MainActor () -> Void)?

    /// - Parameter partition: 目前的會員分區;預設固定一個會員(不必先登入)。
    public init(partition: MemberPartition = .fixed()) {
        self.partition = partition
    }

    private func update(_ change: (inout Records) -> Void) {
        guard let id = partition.memberID else { return }
        change(&partitions[id, default: Records()])
    }

    public var pairings: [String: String] { partition.memberID.flatMap { partitions[$0] }?.pairings ?? [:] }
    public var registeredTokens: [String: String] { partition.memberID.flatMap { partitions[$0] }?.registeredTokens ?? [:] }

    public func setKeyHash(_ keyHash: String?, forHost host: String) {
        update { records in
            if keyHash == nil, let old = records.pairings[host] {
                records.registeredTokens[old] = nil
                records.kinds[old] = nil
            }
            records.pairings[host] = keyHash
        }
        onPairingsChanged?()
    }

    public func setRegisteredToken(_ token: String?, forKeyHash keyHash: String) {
        update { $0.registeredTokens[keyHash] = token }
    }

    public func kinds(forKeyHash keyHash: String) -> Set<PushKind>? {
        partition.memberID.flatMap { partitions[$0] }?.kinds[keyHash]
    }

    public func setKinds(_ kinds: Set<PushKind>?, forKeyHash keyHash: String) {
        update { $0.kinds[keyHash] = kinds }
    }

    public func removePartition(of memberID: String) {
        partitions[memberID] = nil
        onPairingsChanged?()
    }

    public func removeAllPartitions() {
        partitions = [:]
        onPairingsChanged?()
    }

    public func movePartition(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        partitions[newID] = partitions.removeValue(forKey: oldID)
        onPairingsChanged?()
    }
}

/// 存在 `UserDefaults` 的紀錄(只在這支裝置，不同步;雜湊不是祕密)。依會員分區(#405):key 帶會員 ID,
/// 沒有會員時讀到空的、寫入不留下。
@MainActor
public final class UserDefaultsPushPairingStore: PushPairingStore {
    private let defaults: UserDefaults
    private let partition: MemberPartition
    public var onPairingsChanged: (@MainActor () -> Void)?
    /// 舊版(沒有分區)的 key:`MemberLocalState.removeLegacyGlobalState` 升級時清掉。
    static let pairingsKey = "push.pairings"
    static let registeredTokensKey = "push.registeredTokens"
    static let kindsKey = "push.kinds"

    public init(defaults: UserDefaults = .standard, partition: MemberPartition) {
        self.defaults = defaults
        self.partition = partition
    }

    private func read<Value>(_ base: String, as type: Value.Type = Value.self) -> Value? {
        partition.key(base).flatMap { defaults.object(forKey: $0) as? Value }
    }

    private func write(_ value: Any, _ base: String) {
        guard let key = partition.key(base) else { return }
        defaults.set(value, forKey: key)
    }

    public var pairings: [String: String] {
        read(Self.pairingsKey) ?? [:]
    }

    public func setKeyHash(_ keyHash: String?, forHost host: String) {
        guard partition.memberID != nil else { return }
        var pairings = pairings
        if keyHash == nil, let old = pairings[host] {
            setRegisteredToken(nil, forKeyHash: old)
            setKinds(nil, forKeyHash: old)
        }
        pairings[host] = keyHash
        write(pairings, Self.pairingsKey)
        onPairingsChanged?()
    }

    public var registeredTokens: [String: String] {
        read(Self.registeredTokensKey) ?? [:]
    }

    public func setRegisteredToken(_ token: String?, forKeyHash keyHash: String) {
        var tokens = registeredTokens
        tokens[keyHash] = token
        write(tokens, Self.registeredTokensKey)
    }

    /// 存成「雜湊 → 種類原始值陣列」;不認得的值略過。
    public func kinds(forKeyHash keyHash: String) -> Set<PushKind>? {
        guard let stored = read(Self.kindsKey, as: [String: [String]].self)?[keyHash] else { return nil }
        return Set(stored.compactMap(PushKind.init(rawValue:)))
    }

    public func setKinds(_ kinds: Set<PushKind>?, forKeyHash keyHash: String) {
        var stored = read(Self.kindsKey, as: [String: [String]].self) ?? [:]
        stored[keyHash] = kinds.map(PushKind.wireValues)
        write(stored, Self.kindsKey)
    }

    public func removePartition(of memberID: String) {
        for base in [Self.pairingsKey, Self.registeredTokensKey, Self.kindsKey] {
            defaults.removeObject(forKey: "\(base).\(memberID)")
        }
        onPairingsChanged?()
    }

    public func removeAllPartitions() {
        for key in defaults.dictionaryRepresentation().keys {
            for base in [Self.pairingsKey, Self.registeredTokensKey, Self.kindsKey] where key.hasPrefix("\(base).") {
                defaults.removeObject(forKey: key)
            }
        }
        onPairingsChanged?()
    }

    public func movePartition(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        for base in [Self.pairingsKey, Self.registeredTokensKey, Self.kindsKey] {
            defaults.set(defaults.object(forKey: "\(base).\(oldID)"), forKey: "\(base).\(newID)")
            defaults.removeObject(forKey: "\(base).\(oldID)")
        }
        onPairingsChanged?()
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

/// 「傳送測試通知」(#328):請後端或主機對這支裝置送一則測試通知。
/// 正式 app 由主機端送(SSH 主機:`SSHPushTestNotifier` 在主機上對後台 `POST /v1/push` 送 `event: "test"`;HTTPS 主機之後走主機服務);
/// `PushService.testNotifications` 是全域的替身(UI 測試),優先於各主機自己的送出管道(`PushModel.testSender`)。
public protocol PushTestNotificationSending: Sendable {
    func sendTest(hostID: String) async throws
}

/// 推播的共用部分：後台、權限與 token、配對紀錄、這支裝置。每台主機的開關是 `PushModel`。
@MainActor
public final class PushService {
    let session: MemberSession
    let platform: any PushPlatform
    public let store: any PushPairingStore
    let configuration: PushConfiguration
    let isSignedIn: @MainActor () async -> Bool
    private let loadDevice: @MainActor () throws -> PushDeviceIdentity
    private var loadedDevice: PushDeviceIdentity?
    private var models: [WeakPushModel] = []
    /// 傳送測試通知的管道;`nil` 時不提供這個功能。
    public var testNotifications: (any PushTestNotificationSending)?
    /// 主機名稱對應表的共用儲存(App Group,#431);`nil` 時不寫。
    private let hostNameSharing: (any PushHostNameSharing)?
    private var latestHostNames: [String: String] = [:]

    /// - Parameters:
    ///   - loadDevice: 這支裝置(Keychain 的推播 id、預設名稱與型號);讀不到(還沒第一次解鎖)時丟錯，之後用到時再試。
    ///   - isSignedIn: 現在有沒有登入會員(#675:推播只要求登入，不要求 Purrdr Plus)。
    public init(
        session: MemberSession, platform: any PushPlatform, store: any PushPairingStore,
        loadDevice: @escaping @MainActor () throws -> PushDeviceIdentity,
        configuration: PushConfiguration, hostNames hostNameSharing: (any PushHostNameSharing)? = nil,
        isSignedIn: @escaping @MainActor () async -> Bool
    ) {
        self.session = session
        self.platform = platform
        self.store = store
        self.loadDevice = loadDevice
        self.configuration = configuration
        self.hostNameSharing = hostNameSharing
        self.isSignedIn = isSignedIn
        store.onPairingsChanged = { [weak self] in self?.publishHostNames() }
    }

    /// 主機名稱(主機 id → 顯示名稱)有變時由 `HostsModel` 呼叫(#431);連同目前的配對寫成「配對雜湊 → 名稱」。
    public func updateHostNames(_ names: [String: String]) {
        latestHostNames = names
        publishHostNames()
    }

    /// 第一個 frame 之後才寫對應表(#590);沒設閘就立刻寫。
    public var launchGate: LaunchGate?
    private var hostNamesPublishDeferred = false

    private func publishHostNames() {
        guard hostNameSharing != nil else { return }
        if let launchGate, !launchGate.isOpen {
            guard !hostNamesPublishDeferred else { return }
            hostNamesPublishDeferred = true
            launchGate.run { [weak self] in
                Task { @MainActor in
                    self?.hostNamesPublishDeferred = false
                    self?.writeHostNames()
                }
            }
            return
        }
        writeHostNames()
    }

    private func writeHostNames() {
        hostNameSharing?.save(PushHostNameMap.make(pairings: store.pairings, hostNames: latestHostNames))
    }

    /// 這支裝置已知時(測試、UI 測試)。
    public convenience init(
        session: MemberSession, platform: any PushPlatform, store: any PushPairingStore, device: PushDeviceIdentity,
        configuration: PushConfiguration, hostNames hostNameSharing: (any PushHostNameSharing)? = nil,
        isSignedIn: @escaping @MainActor () async -> Bool
    ) {
        self.init(
            session: session, platform: platform, store: store, loadDevice: { device }, configuration: configuration,
            hostNames: hostNameSharing, isSignedIn: isSignedIn)
    }

    /// 這支裝置;第一次成功讀到後記住。
    public func device() throws -> PushDeviceIdentity {
        if let loadedDevice { return loadedDevice }
        let device = try loadDevice()
        loadedDevice = device
        return device
    }

    /// 啟動時：先判斷這支裝置是否已被遠端關閉，判斷得了才補註冊(避免把被撤銷的配對註冊回來)。
    public func refreshAtLaunch() async {
        guard await reconcileRemoteRevocation() else { return }
        await refreshRegistrations()
    }

    /// 對還沒以目前 token 帶裝置 id 註冊過的配對(token 輪替、舊版 app)向後台註冊，逐組記錄成功與否。
    /// 主機上的配對檔只有密鑰，不必改。失敗的下次再試。
    public func refreshRegistrations() async {
        guard !store.pairings.isEmpty, let device = try? device(), await platform.authorization() == .authorized,
              let token = try? await platform.deviceToken() else { return }
        let hex = Self.hex(token)
        for keyHash in store.pairings.values.sorted() where store.registeredTokens[keyHash] != hex {
            do {
                // 沒記過種類(舊版 app 開的)不帶，後台保留原本的偏好。
                try await session.registerPushPairing(
                    keyHash: keyHash, deviceToken: hex, environment: configuration.environment, device: device,
                    kinds: store.kinds(forKeyHash: keyHash))
                store.setRegisteredToken(hex, forKeyHash: keyHash)
            } catch {
                continue
            }
        }
    }

    /// 這支裝置已不在後台的「通知裝置」(被別支裝置關閉)就清掉帶裝置 id 註冊過的配對，「通知」區塊回到關閉。
    /// 判斷得了(或不需要判斷)回 `true`;讀不到清單或這支裝置的 id 時回 `false`。
    @discardableResult
    public func reconcileRemoteRevocation() async -> Bool {
        guard store.pairings.values.contains(where: { store.registeredTokens[$0] != nil }) else { return true }
        guard let device = try? device(),
              let devices = try? await session.pushDevices(currentDeviceID: device.id.backendValue) else { return false }
        reconcile(with: devices)
        return true
    }

    /// 清單裡沒有這支裝置時，清掉帶裝置 id 註冊過的配對(舊版 app 註冊的不在清單裡，留著等補註冊)。
    func reconcile(with devices: [PushDevice]) {
        guard let device = try? device(),
              !devices.contains(where: { $0.isCurrent || $0.id == device.id.backendValue }) else { return }
        let revoked = store.pairings.filter { store.registeredTokens[$0.value] != nil }.keys
        guard !revoked.isEmpty else { return }
        forget(hosts: Array(revoked))
    }

    /// 這支裝置的後台配對已全部撤銷：清掉本機紀錄，主機上的殘留配對由外掛收到 410 時清掉。
    func forgetAllPairings() {
        forget(hosts: Array(store.pairings.keys))
    }

    private func forget(hosts: [String]) {
        for host in hosts {
            store.setKeyHash(nil, forHost: host)
        }
        models.removeAll { $0.model == nil }
        for entry in models {
            entry.model?.pairingRevoked()
        }
    }

    /// 會員分區換了(登入、登出、換會員)或被清除後:各主機的開關重讀本機紀錄。
    public func reloadModels() {
        publishHostNames()
        models.removeAll { $0.model == nil }
        for entry in models {
            entry.model?.reloadFromStore()
        }
    }

    func track(_ model: PushModel) {
        models.removeAll { $0.model == nil }
        models.append(WeakPushModel(model: model))
    }

    /// `forget` 刪完配對後不做任何事(預設值用常數，見 `AsyncDefaultArgumentTests`)。
    nonisolated public static let nothingAfterRemoving: @Sendable () async -> Void = {}

    /// 移除主機時：不等待地刪掉那台主機上的配對並撤銷(行為規格 F14)。刪完配對後呼叫 `afterRemoving`(例如關閉為此另開的連線)。
    public func forget(
        hostID: String, installer: any PushPluginInstalling,
        afterRemoving: @escaping @Sendable () async -> Void = PushService.nothingAfterRemoving
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

    /// 這支裝置在某台主機的推播外掛安裝：每次操作才讀裝置 id(Keychain 可能還沒解鎖),讀不到丟 `PushDeviceIDError`。
    public func installer(_ make: @escaping @Sendable (PushDeviceID) -> any PushPluginInstalling) -> any PushPluginInstalling {
        DeviceBoundPushPluginInstaller(deviceID: { [weak self] in
            guard let self else { throw CancellationError() }
            return try self.device().id
        }, make: make)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// 操作時才取得裝置 id 的推播外掛安裝。
private struct DeviceBoundPushPluginInstaller: PushPluginInstalling {
    let deviceID: @MainActor @Sendable () throws -> PushDeviceID
    let make: @Sendable (PushDeviceID) -> any PushPluginInstalling

    private func resolved() async throws -> any PushPluginInstalling {
        let id = try await deviceID()
        return make(id)
    }

    func status() async throws -> PushPluginStatus { try await resolved().status() }
    func install(_ pairing: PushPairingFile) async throws { try await resolved().install(pairing) }
    func remove() async throws { try await resolved().remove() }
    func updateMuted(_ muted: Set<String>) async throws { try await resolved().updateMuted(muted) }
    func updatePluginIfNeeded() async throws -> Bool { try await resolved().updatePluginIfNeeded() }
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
        /// 還沒登入(或登入已失效):先登入會員。
        case needsSignIn
        /// 通知權限被拒：到 iOS 設定打開。
        case permissionDenied
        /// 取不到 APNs token(模擬器、缺 entitlement);附原始錯誤。
        case unsupportedDevice(DisplayedError)
        /// 主機服務太舊，不能代裝外掛：附依已安裝版本的更新指令。
        case hostServiceOutdated(HostServiceUpdateCommands)
        /// Keychain 讀不到這支裝置的推播 id(裝置還沒第一次解鎖);稍後再試。
        case deviceIDUnavailable(DisplayedError)
        /// 通知開著，但主機上的靜音清單沒改成;附原因。
        case mutedSyncFailed(DisplayedError)
        /// 通知開著，但要收的種類沒改成(維持原本的);附原因。
        case kindsUpdateFailed(DisplayedError)
        case failed(DisplayedError)
    }

    public private(set) var state: State = .off
    public var problem: Problem?
    /// 這台主機上另外幾支裝置開著通知(上次查狀態的結果;不列出是哪些裝置)。
    public private(set) var otherDevices = 0
    /// 上次查狀態時主機外掛已裝(別的裝置或使用者裝的):開啟只新增這支裝置的配對。
    public private(set) var pluginAlreadyInstalled = false
    /// 這台主機要收的推播種類(開著時才有意義)。
    public private(set) var kinds: Set<PushKind> = PushModel.defaultKinds
    /// 正在向後台改種類。
    public private(set) var isUpdatingKinds = false

    /// 新開啟的主機預設收的種類。
    public static let defaultKinds: Set<PushKind> = [.blocked, .done]
    /// 舊版 app 開的配對沒記種類：後台當成只收「需要你」。
    static let legacyKinds: Set<PushKind> = [.blocked]

    private let service: PushService?
    private let hostID: String?
    private let installer: (any PushPluginInstalling)?
    private let muted: @MainActor () -> Set<String>
    private var deviceToken: Data?

    /// - Parameters:
    ///   - service: `nil` 時這個 app 沒有推播(例如 UI 測試以外沒設定)。
    ///   - hostID: 主機 id;Demo 主機是 `nil`。
    ///   - installer: 這支裝置在這台主機的推播外掛安裝;`nil` 時這台主機沒有推播。
    ///   - muted: 目前靜音的聊天(session 值,存在本機的聊天偏好),配對時寫進主機。
    ///   - testSender: 這台主機自己的測試通知送出管道;`nil` 時沒有(`PushService.testNotifications` 有值時以它為準)。
    public init(service: PushService?, hostID: String?, installer: (any PushPluginInstalling)?,
                testSender: (any PushTestNotificationSending)? = nil,
                muted: @escaping @MainActor () -> Set<String>) {
        self.testSender = testSender
        self.service = service
        self.hostID = hostID
        self.installer = installer
        self.muted = muted
        if let hostID, let store = service?.store, let keyHash = store.keyHash(forHost: hostID) {
            state = .on
            kinds = store.kinds(forKeyHash: keyHash) ?? Self.legacyKinds
        }
        service?.track(self)
    }

    /// 會員分區換了:依目前會員的本機紀錄回到開著或關閉(進行中的開關動作不打斷)。
    func reloadFromStore() {
        guard let hostID, let store = service?.store else { return }
        switch state {
        case .off, .on:
            break
        default:
            return
        }
        problem = nil
        if let keyHash = store.keyHash(forHost: hostID) {
            state = .on
            kinds = store.kinds(forKeyHash: keyHash) ?? Self.legacyKinds
        } else {
            state = .off
            kinds = Self.defaultKinds
        }
    }

    /// 這支裝置被遠端關閉(配對已撤銷):回到關閉。
    func pairingRevoked() {
        guard state == .on, let hostID, service?.store.keyHash(forHost: hostID) == nil else { return }
        state = .off
    }

    public var isAvailable: Bool { service != nil && installer != nil }

    /// 測試通知的結果。
    public enum TestNotification: Equatable {
        case idle
        case sending
        case sent
        case failed(DisplayedError)
    }

    public private(set) var testNotification: TestNotification = .idle

    /// 這台主機自己的測試通知送出管道(SSH 主機由 `HostsModel` 接上);`PushService.testNotifications` 有值時以它為準。
    public let testSender: (any PushTestNotificationSending)?

    private var testNotificationSender: (any PushTestNotificationSending)? { service?.testNotifications ?? testSender }

    /// 通知開著、而且有送出管道時才能送測試通知。
    public var canSendTestNotification: Bool {
        state == .on && hostID != nil && testNotificationSender != nil
    }

    /// 使用者看過結果提示(或重新開始)。
    public func dismissTestNotification() {
        if testNotification != .sending { testNotification = .idle }
    }

    /// 送測試通知;結果在 `testNotification`(失敗附原因)。
    public func sendTestNotification() async {
        guard canSendTestNotification, testNotification != .sending,
              let sender = testNotificationSender, let hostID else { return }
        testNotification = .sending
        do {
            try await sender.sendTest(hostID: hostID)
            testNotification = .sent
        } catch PushTestNotificationError.notPaired {
            // 主機上已沒有有效配對(被刪、後台已撤銷):與改靜音遇到 notPaired 相同，這台回到未開啟並撤銷後台配對，使用者重新開啟。
            testNotification = .failed(DisplayedError(
                Self.describeTestFailure(PushTestNotificationError.notPaired), error: PushTestNotificationError.notPaired))
            if let service, let keyHash = service.store.keyHash(forHost: hostID) {
                service.store.setKeyHash(nil, forHost: hostID)
                let session = service.session
                Task { try? await session.revokePushPairing(keyHash: keyHash) }
            }
            state = .off
            problem = nil
        } catch {
            testNotification = .failed(DisplayedError(Self.describeTestFailure(error), error: error))
        }
    }

    /// 使用者打開開關。
    public func requestOn() async {
        guard state == .off, let service, let installer else { return }
        problem = nil
        guard hostID != nil else {
            problem = .demoHost
            return
        }
        do { _ = try service.device() } catch { return stop(Self.deviceIDUnavailable(error)) }
        state = .checking
        guard await service.isSignedIn() else { return stop(.needsSignIn) }
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
            return stop(.unsupportedDevice(DisplayedError(error.localizedDescription, error: error)))
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
        let device: PushDeviceIdentity
        do { device = try service.device() } catch { return stop(Self.deviceIDUnavailable(error)) }
        state = .turningOn
        let key = PushPairingKey.generate()
        let tokenHex = PushService.hex(deviceToken)
        do {
            try await service.session.registerPushPairing(
                keyHash: key.hash, deviceToken: tokenHex, environment: service.configuration.environment, device: device,
                kinds: Self.defaultKinds)
        } catch BackendError.signedOut {
            return stop(.needsSignIn)
        } catch {
            return stop(.failed(DisplayedError(Self.describe(error), error: error)))
        }
        do {
            let file = PushPairingFile(endpoint: service.configuration.endpoint, key: key, muted: muted())
            try await installer.install(file)
        } catch {
            try? await service.session.revokePushPairing(keyHash: key.hash)
            return stop(Self.problem(for: error))
        }
        service.store.setKeyHash(key.hash, forHost: hostID)
        service.store.setRegisteredToken(tokenHex, forKeyHash: key.hash)
        service.store.setKinds(Self.defaultKinds, forKeyHash: key.hash)
        kinds = Self.defaultKinds
        state = .on
    }

    /// 使用者改這台主機要收的種類：以同一組配對向後台重送註冊。失敗維持原本的種類並說明;最後一個種類不能關。
    public func setKind(_ kind: PushKind, isOn: Bool) async {
        guard state == .on, !isUpdatingKinds, let service, let hostID,
              let keyHash = service.store.keyHash(forHost: hostID) else { return }
        var updated = kinds
        if isOn {
            updated.insert(kind)
        } else {
            updated.remove(kind)
        }
        guard updated != kinds, !updated.isEmpty else { return }
        isUpdatingKinds = true
        defer { isUpdatingKinds = false }
        if case .kindsUpdateFailed = problem { problem = nil }
        do {
            let device = try service.device()
            let token = try await service.platform.deviceToken()
            let tokenHex = PushService.hex(token)
            try await service.session.registerPushPairing(
                keyHash: keyHash, deviceToken: tokenHex, environment: service.configuration.environment, device: device,
                kinds: updated)
            service.store.setKinds(updated, forKeyHash: keyHash)
            service.store.setRegisteredToken(tokenHex, forKeyHash: keyHash)
            kinds = updated
        } catch BackendError.signedOut {
            problem = .needsSignIn
        } catch {
            problem = .kindsUpdateFailed(DisplayedError(Self.describeKindsFailure(error), error: error))
        }
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
            problem = .failed(DisplayedError(
                String(localized: "Notifications are off, but the notification helper couldn’t be removed: \(message)"),
                error: PushPluginError.pluginUninstallFailed(message)))
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
        kinds = Self.defaultKinds
        state = .off
    }

    /// 查這台主機的推播狀態(另有幾支裝置開著)。查不到就維持上次的結果，不顯示錯誤。
    public func refreshStatus() async {
        guard let installer, hostID != nil, let status = try? await installer.status() else { return }
        record(status)
    }

    /// 距離上次嘗試更新外掛至少這麼久才再試(#432;成功與失敗都算)。
    public static let pluginUpdateInterval: Duration = .seconds(24 * 60 * 60)
    private var lastPluginUpdateAttempt: ContinuousClock.Instant?

    /// 推播開著時，外掛版本落後就更新(#432,SSH 主機;主機服務自己更新，其安裝介面什麼都不做)。
    /// 頻率上限 `pluginUpdateInterval`;失敗不打擾使用者，下個間隔再試。
    @discardableResult
    public func updatePluginIfNeeded(now: ContinuousClock.Instant = .now) async -> Bool {
        guard state == .on, let installer else { return false }
        if let last = lastPluginUpdateAttempt, now - last < Self.pluginUpdateInterval { return false }
        lastPluginUpdateAttempt = now
        return (try? await installer.updatePluginIfNeeded()) ?? false
    }

    private func record(_ status: PushPluginStatus) {
        otherDevices = status.otherPairedDevices
        pluginAlreadyInstalled = status.pluginInstalled
    }

    /// 靜音清單改了：推播開著時改寫主機上的配對檔(iOS 在 app 能攔截前就顯示推播，靜音只能在主機端生效)。
    /// 主機上已沒有這支裝置的配對(被手動移除)就回到關閉並撤銷後台配對;其他失敗在這台主機列說明。
    public func syncMuted(_ muted: Set<String>) async {
        guard state == .on, let service, let installer, let hostID else { return }
        do {
            try await installer.updateMuted(muted)
            if case .mutedSyncFailed = problem { problem = nil }
        } catch PushPluginError.notPaired {
            guard let keyHash = service.store.keyHash(forHost: hostID) else { return }
            service.store.setKeyHash(nil, forHost: hostID)
            state = .off
            problem = nil
            let session = service.session
            Task { try? await session.revokePushPairing(keyHash: keyHash) }
        } catch {
            problem = .mutedSyncFailed(DisplayedError(
                String(localized: "Couldn’t update muted chats on this host: \(error.localizedDescription)"), error: error))
        }
    }

    public func openSystemSettings() {
        service?.platform.openSettings()
    }

    private func stop(_ problem: Problem) {
        state = .off
        self.problem = problem
    }

    private static func deviceIDUnavailable(_ error: any Error) -> Problem {
        .deviceIDUnavailable(DisplayedError(String(localized: "Couldn’t read this device’s ID. Unlock this device and try again."), error: error))
    }

    static func problem(for error: any Error) -> Problem {
        switch error {
        case PushPluginError.hostServiceOutdated(let installed):
            .hostServiceOutdated(HostServiceUpdates.commands(installed: installed))
        case is PushDeviceIDError:
            deviceIDUnavailable(error)
        default:
            .failed(DisplayedError(describe(error), error: error))
        }
    }

    static func describeKindsFailure(_ error: any Error) -> String {
        switch error {
        case BackendError.unreachable:
            describe(error)
        case is PushDeviceIDError:
            String(localized: "Couldn’t read this device’s ID. Unlock this device and try again.")
        default:
            String(localized: "Couldn’t change which notifications this host sends: \(error.localizedDescription)")
        }
    }

    package static func describeTestFailure(_ error: any Error) -> String {
        switch error {
        case BackendError.unreachable:
            String(localized: "Couldn’t reach Purrdr’s server. Check your connection and try again.")
        case BackendError.signedOut:
            String(localized: "Couldn’t send the test notification because you’re signed out. Sign in again and try once more.")
        case PushTestNotificationError.notPaired:
            String(localized: "This device isn’t paired with the host for notifications any more, so they’re now off. Turn them on again.")
        case PushTestNotificationError.subscriptionRequired:
            String(localized: "Test notifications need Purrdr Plus.")
        case PushTestNotificationError.dailyLimitReached:
            String(localized: "You’ve reached today’s limit for test notifications. Try again tomorrow.")
        case PushTestNotificationError.rateLimited:
            String(localized: "You’ve sent too many notifications in a minute. Wait a moment and try again.")
        case PushTestNotificationError.apnsFailed:
            String(localized: "Apple’s notification service didn’t accept the test notification. Try again in a moment.")
        case PushTestNotificationError.curlMissing:
            String(localized: "The host needs curl to send a test notification.")
        case PushTestNotificationError.backendUnreachable:
            String(localized: "The host couldn’t reach Purrdr’s server. Check the host’s internet connection and try again.")
        default:
            // 系統或後台的原文使用者看不懂也幫不上忙:只說沒送出、稍後再試。
            String(localized: "Couldn’t send the test notification. Try again in a moment.")
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case PushPluginError.pluginInstallFailed(let message):
            String(localized: "Couldn’t install the notification helper: \(message)")
        case PushPluginError.pluginListFailed(let message):
            String(localized: "Couldn’t check notifications on this host. Make sure herdr is running there. \(message)")
        case HostServiceError.readOnlyDevice:
            String(localized: "This device is paired read-only with the host service, so it can’t turn on notifications there.")
        case BackendError.unreachable:
            String(localized: "Couldn’t reach Purrdr’s server. Check your connection and try again.")
        case BackendError.backend(_, "daily_limit_reached", _):
            String(localized: "You’ve reached today’s limit for notification setups. Try again tomorrow.")
        default:
            String(localized: "Couldn’t turn on notifications: \(error.localizedDescription)")
        }
    }
}

/// 點通知時要開的畫面:payload 根層的 `pairing`(配對密鑰雜湊 → 主機)、`pane` 或主機服務的 `event`(後台組的,`raychiutw/purrdr.server` 的 `src/push.ts`)。
public struct PushRoute: Equatable, Sendable {
    public var keyHash: String
    public var paneID: String?
    /// 主機服務事件(#293,如 `host_service_updated`);有值時開那台主機的編輯頁，不開聊天。
    public var event: String?
    /// 帳號頁「傳送測試通知」(#328)的 `event`:只開 app,不開任何畫面。
    public static let testEvent = "test"

    public init(keyHash: String, paneID: String?, event: String? = nil) {
        self.keyHash = keyHash
        self.paneID = paneID
        self.event = event
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let keyHash = userInfo["pairing"] as? String, !keyHash.isEmpty else { return nil }
        let event = (userInfo["event"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(keyHash: keyHash, paneID: userInfo["pane"] as? String, event: event)
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
