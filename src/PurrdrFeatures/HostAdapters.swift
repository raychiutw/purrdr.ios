import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

// 主機能力 adapter(#563、spec #555):SSH、HTTPS、Demo 各一個,一次交出型別化的能力組,
// 每項沒有的能力都帶原因。主機清單與成員只依能力組工作,不再依連線方式分支、不再以 `as?` 判斷能力。
// 連線方式的差異(含 `as?` 轉型)只留在這個檔案的 adapter 內。

/// 一項能力:有就交出實作,沒有就說明原因(畫面或診斷依原因決定怎麼說)。
enum HostCapability<Value> {
    case available(Value)
    case unavailable(HostCapabilityGap)

    var value: Value? {
        if case .available(let value) = self { value } else { nil }
    }

    var gap: HostCapabilityGap? {
        if case .unavailable(let gap) = self { gap } else { nil }
    }
}

/// 一項能力「沒有」的原因。
enum HostCapabilityGap: Equatable, Sendable {
    /// Demo 主機與示範主機:沒有真的後端。
    case demoHost
    /// 這種連線方式做不到(例如 HTTPS 主機沒有主機通道)。
    case notOfferedByConnectionMethod
    /// 這條連線(例如 UI 測試的替身連線)沒有實作這項。
    case connectionLacksSupport
}

/// 由推播服務建出這台主機的推播外掛安裝。
typealias HostPushInstallerMaker = @MainActor (PushService) -> any PushPluginInstalling
/// 由推播服務建出這台主機的測試通知送出管道。
typealias HostPushTestSenderMaker = @MainActor (PushService) -> any PushTestNotificationSending

/// 一台主機交給成員的能力組。
struct HostCapabilities {
    /// 上層功能(herdr client、對話紀錄、Pane 終端機)用的連線。
    var connection: any HostConnection
    /// 只有 SSH 才有的功能(登入 Shell、主題、資料夾…)用的通道;沒有時是 `UnsupportedHostChannel`。
    var channel: any HostChannel
    /// 主題、註記、方案用量定期讀取共用的長駐通道。
    var hostFiles: HostFiles
    var files: any HostFileFetching
    var uploads: any HostUploading
    var git: any GitChangesReading
    /// 新增聊天的資料夾建議:SSH 經通道列資料夾,HTTPS 沒有通道、只收完整路徑(#287)。
    var folders: NewChatFolders
    /// Claude status line 的 session 狀態;讀不到時 context 退回對話紀錄算法。
    var sessionStatus: any ClaudeSessionStatusReading
    var antigravityStatus: HostCapability<any ClaudeSessionStatusReading>
    var sendWhenDone: HostCapability<any SendWhenDoneHosting>
    var pushInstaller: HostCapability<HostPushInstallerMaker>
    var pushTestSender: HostCapability<HostPushTestSenderMaker>
    /// 經主機服務讀方案用量(0.12.0 起)用的連線;SSH 主機走 `channel`。
    var hostServiceConnection: HostCapability<HTTPSHostConnection>
    /// 這台主機寫入主機的同意紀錄(Demo 與真主機分開)。
    var consent: any HostWriteConsentStore
}

/// 取不到主機服務連線(UI 測試的替身連線)時沒有 session 狀態,context 用對話紀錄算法(#388)。
struct UnavailableSessionStatus: ClaudeSessionStatusReading {
    func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus] { [:] }
}

/// 流量計量的接線,全 app 只有這一處:連線或通道建好後接上這台主機的記錄器。
@MainActor
struct HostTrafficWiring {
    var meter: @MainActor () -> TrafficMeter?

    func recorder(for hostID: UUID) -> TrafficRecording? { meter()?.recorder(for: hostID.uuidString) }

    func wire(_ channel: any HostChannel, hostID: UUID) {
        guard let recorder = recorder(for: hostID) else { return }
        (channel as? SSHHostChannel)?.attachTraffic(recorder)
    }

    func wire(_ connection: any HostConnection, hostID: UUID) {
        guard let recorder = recorder(for: hostID) else { return }
        (connection as? HTTPSHostConnection)?.attachTraffic(recorder)
    }
}

/// 三個 adapter 共用的依賴。
@MainActor
struct HostAdapterEnvironment {
    var makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    var credentials: HostCredentials
    var hostService: HostServiceAccess
    var pushService: PushService?
    var traffic: HostTrafficWiring
    var diagnostics: DiagnosticLog
    /// 偵測到作業系統時存回主機設定。
    var recordOperatingSystem: @MainActor (HostOperatingSystem, UUID) async -> Void
    /// 這台主機要用的同意紀錄。
    var consent: any HostWriteConsentStore
    /// 新增聊天／續接的步驟與 SSH 關鍵請求的耗時(#635);建立連線時讀。
    var operationTimings: @MainActor () -> OperationTimingSink? = { nil }
}

/// 刪除主機時,adapter 收尾要用的資料(祕密與權杖在刪掉前先讀出來)。
struct HostRemoval {
    var configuration: HostConfiguration
    var secret: HostSecret?
    var deviceToken: String?
    /// 這支裝置曾用密碼加入公鑰(同意紀錄還在):要還原。
    var restoresDeviceKey: Bool
}

/// 主機上有哪些 Agent 的偵測方式。
enum HostAgentDetection: Equatable, Sendable {
    /// 看家目錄的設定資料夾(唯讀),一次就讀得到。
    case configFolders
    /// 看列表已讀到的 herdr 快照:要等列表讀到才有,最多重試 `attempts` 次,只看得到正在跑的 Agent。
    case snapshot(attempts: Int)

    var attempts: Int {
        switch self {
        case .configFolders: 1
        case .snapshot(let attempts): attempts
        }
    }
}

/// 一種連線方式固定的性質:主機清單與成員問 adapter,不自己依連線方式分支。
struct HostAdapterTraits: Equatable, Sendable {
    /// 經主機服務(裝置權杖、主機服務版本與更新、配對、唯讀裝置)。
    var usesHostService: Bool
    var agentDetection: HostAgentDetection

    static let ssh = HostAdapterTraits(usesHostService: false, agentDetection: .configFolders)
    static let hostService = HostAdapterTraits(usesHostService: true, agentDetection: .snapshot(attempts: 10))
}

/// 一種連線方式的 adapter。
@MainActor
protocol HostAdapter: AnyObject {
    var traits: HostAdapterTraits { get }
    /// 主機清單列的副標題(位址)。
    func addressDescription(of configuration: HostConfiguration) -> String
    /// 這台主機的能力組;同一台主機的連線在 adapter 內重用。
    func capabilities(for configuration: HostConfiguration) -> HostCapabilities
    /// 目前持有的主機通道(喚醒探測與網路切換用)。
    var liveChannels: [UUID: any HostChannel] { get }
    /// 丟掉這台主機的連線(設定改了或刪除);背景關閉,回傳的 task 結束時連線已關。
    @discardableResult
    func drop(_ id: UUID) -> Task<Void, Never>?
    /// 刪除主機時的收尾(推播配對、公鑰、權杖撤銷):用另開的臨時連線,做完關閉。
    func cleanUpAfterRemoval(_ removal: HostRemoval)
    /// 所有連線的關閉動作(網路路徑改變時丟棄用)。
    func disconnectors() -> [@Sendable () async -> Void]
    /// 預先撥號(#550):回前景丟掉連線後立刻建立新連線,後面的畫面請求沿用它。失敗不處理(請求自己會重試)。
    func prewarmers() -> [@Sendable () async -> Void]
}

extension HostAdapter {
    func prewarmers() -> [@Sendable () async -> Void] { [] }
}

// MARK: - 以通道為基礎的能力組(SSH 與 Demo 共用)

enum ChannelCapabilities {
    /// - Parameters:
    ///   - files: 主機取檔;`nil` 時經 `channel` 跑 SSH 的取檔腳本。
    ///   - herdr: 具名 session 與安裝位置;Demo 與還沒設定的主機用預設。
    ///   - hostName: 有值才提供測試通知(Demo 主機沒有真的外掛)。
    @MainActor
    static func make(
        channel: any HostChannel, herdr: HerdrInstallation, files: (any HostFileFetching)? = nil, hostName: String?,
        consent: any HostWriteConsentStore, timings: OperationTimingSink? = nil
    ) -> HostCapabilities {
        let hostFiles = HostFiles.longRunning(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-files"))
        let connection = SSHHostConnection(
            channel: channel, herdr: herdr, followDiagnostics: DiagnosticLog.systemNotice(category: "transcript-follow"), timings: timings)
        return HostCapabilities(
            connection: connection, channel: channel, hostFiles: hostFiles,
            files: files ?? SSHHostFileFetcher(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-file-fetch")),
            uploads: SSHHostUploader(channel: channel), git: SSHGitChanges(channel: channel),
            folders: NewChatFolders(channel: channel),
            sessionStatus: ClaudePlanUsageHost(channel: channel, files: hostFiles),
            antigravityStatus: .available(AntigravityPlanUsageHost(channel: channel, files: hostFiles)),
            // Send When Done 要主機服務的 Agent 觀察者(#305)。
            sendWhenDone: .unavailable(.notOfferedByConnectionMethod),
            pushInstaller: .available { $0.sshInstaller(channel: channel, herdr: herdr) },
            pushTestSender: hostName.map { name in
                // Windows 也有 PowerShell 版,所以不分作業系統。
                .available { SSHPushTestSender(service: $0, channel: channel, hostName: name) }
            } ?? .unavailable(.demoHost),
            hostServiceConnection: .unavailable(.notOfferedByConnectionMethod), consent: consent)
    }
}

// MARK: - SSH(Tailscale SSH 與一般 OpenSSH)

@MainActor
final class SSHHostAdapter: HostAdapter {
    private let environment: HostAdapterEnvironment
    private var channels: [UUID: any HostChannel] = [:]

    init(environment: HostAdapterEnvironment) { self.environment = environment }

    var liveChannels: [UUID: any HostChannel] { channels }
    var traits: HostAdapterTraits { .ssh }

    func addressDescription(of configuration: HostConfiguration) -> String {
        configuration.ssh.map { "\($0.endpoint.username)@\($0.endpoint.host):\($0.endpoint.port)" } ?? ""
    }

    func capabilities(for configuration: HostConfiguration) -> HostCapabilities {
        guard let settings = configuration.ssh else { return Self.blocked(configuration, consent: environment.consent) }
        return ChannelCapabilities.make(
            channel: channel(for: configuration, settings: settings), herdr: settings.herdr, hostName: configuration.name,
            consent: environment.consent, timings: environment.operationTimings())
    }

    /// 還沒重新確認的主機(#572):不開任何連線。
    static func blocked(_ configuration: HostConfiguration, consent: any HostWriteConsentStore) -> HostCapabilities {
        ChannelCapabilities.make(
            channel: UnsupportedHostChannel(), herdr: configuration.ssh?.herdr ?? HerdrInstallation(), hostName: configuration.name,
            consent: consent)
    }

    private func channel(for host: HostConfiguration, settings: HostConfiguration.SSHSettings) -> any HostChannel {
        if let channel = channels[host.id] { return channel }
        // Windows 主機的指令換成 PowerShell 方言(#26);作業系統未知(主機同步帶來的新主機)時先偵測，
        // 不對可能是 Windows 的主機送 POSIX 指令。
        let base = environment.makeChannel(settings.endpoint, settings.hostKeyPin, environment.credentials.provider(for: host))
        environment.traffic.wire(base, hostID: host.id)
        let id = host.id
        let record = environment.recordOperatingSystem
        let channel = host.operatingSystem?.channel(base) ?? OperatingSystemDetectingChannel(base) { operatingSystem in
            await record(operatingSystem, id)
        }
        channels[host.id] = channel
        return channel
    }

    @discardableResult
    func drop(_ id: UUID) -> Task<Void, Never>? {
        guard let channel = channels.removeValue(forKey: id) else { return nil }
        return Task { await channel.disconnect() }
    }

    func disconnectors() -> [@Sendable () async -> Void] {
        channels.values.map { channel in { await channel.disconnect() } }
    }

    func prewarmers() -> [@Sendable () async -> Void] {
        channels.values.map { channel in { await WakeProbe(channel: channel).dial() } }
    }

    func cleanUpAfterRemoval(_ removal: HostRemoval) {
        guard let settings = removal.configuration.ssh else { return }
        forgetPush(removal.configuration, settings: settings, secret: removal.secret)
        if removal.restoresDeviceKey { restoreDeviceKey(removal.configuration, settings: settings, secret: removal.secret) }
    }

    /// 臨時連線:刪除主機會關閉它原本的連線,所以另開一條不放進 `channels` 的。
    private func temporaryChannel(
        _ host: HostConfiguration, settings: HostConfiguration.SSHSettings, secret: HostSecret?
    ) -> any HostChannel {
        let provider = environment.credentials.provider(
            method: host.connectionMethod, authentication: host.authentication, hostID: nil, entered: secret)
        let channel = environment.makeChannel(settings.endpoint, settings.hostKeyPin, provider)
        environment.traffic.wire(channel, hostID: host.id)
        return channel
    }

    /// 推播配對:刪掉主機上的配對,刪完關閉臨時連線。
    private func forgetPush(_ host: HostConfiguration, settings: HostConfiguration.SSHSettings, secret: HostSecret?) {
        guard let pushService = environment.pushService else { return }
        let channel = temporaryChannel(host, settings: settings, secret: secret)
        pushService.forget(
            hostID: host.id.uuidString, installer: pushService.sshInstaller(channel: channel, herdr: settings.herdr)
        ) {
            await channel.disconnect()
        }
    }

    /// 用密碼加入的公鑰(#285):另開一條連線還原 `authorized_keys`(ADR-0002),不等待;主機離線時留在主機上。
    private func restoreDeviceKey(_ host: HostConfiguration, settings: HostConfiguration.SSHSettings, secret: HostSecret?) {
        let deviceKey = environment.credentials.deviceKey
        let base = temporaryChannel(host, settings: settings, secret: secret)
        let channel = host.operatingSystem?.channel(base) ?? OperatingSystemDetectingChannel(base) { _ in }
        let diagnostics = environment.diagnostics
        Task {
            do {
                try await AuthorizedKeyInstaller(channel: channel).restore(try deviceKey.publicKey())
            } catch {
                diagnostics.error("Couldn’t remove this device’s key from host \(host.id): \(error)")
            }
            await base.disconnect()
        }
    }
}

// MARK: - HTTPS(主機服務)

@MainActor
final class HTTPSHostAdapter: HostAdapter {
    private let environment: HostAdapterEnvironment
    private var connections: [UUID: any HostConnection] = [:]

    init(environment: HostAdapterEnvironment) { self.environment = environment }

    /// HTTPS 主機沒有主機通道。
    var liveChannels: [UUID: any HostChannel] { [:] }
    var traits: HostAdapterTraits { .hostService }

    func addressDescription(of configuration: HostConfiguration) -> String {
        configuration.hostService?.description ?? ""
    }

    /// 這台主機重用的連線(版本檢查、主機狀態頁、方案用量與能力組共用同一條);不是 HTTPS 主機時是 `nil`。
    func connection(for configuration: HostConfiguration) -> (any HostConnection)? {
        guard case .https(let address) = configuration.connection else { return nil }
        if let connection = connections[configuration.id] { return connection }
        let connection = environment.hostService.connection(for: configuration, address: address)
        environment.traffic.wire(connection, hostID: configuration.id)
        connections[configuration.id] = connection
        return connection
    }

    func capabilities(for configuration: HostConfiguration) -> HostCapabilities {
        guard let connection = connection(for: configuration) else { return SSHHostAdapter.blocked(configuration, consent: environment.consent) }
        let channel = UnsupportedHostChannel()
        let hostFiles = HostFiles.longRunning(channel: channel, diagnostics: DiagnosticLog.systemNotice(category: "host-files"))
        let https = connection as? HTTPSHostConnection
        let name = configuration.name
        return HostCapabilities(
            connection: connection, channel: channel, hostFiles: hostFiles,
            // 主機取檔、上傳、git 與 session 狀態走同一條主機服務連線(#227、#310、#388);UI 測試的替身連線沒有。
            files: (connection as? any HostFileFetching) ?? UnsupportedHostFileFetcher(),
            uploads: (connection as? any HostUploading) ?? SSHHostUploader(channel: channel),
            git: (connection as? any GitChangesReading) ?? UnsupportedGitChanges(), folders: .absolutePathsOnly,
            sessionStatus: (connection as? any ClaudeSessionStatusReading) ?? UnavailableSessionStatus(),
            // Antigravity 的包裝經 SSH 寫入,主機服務沒有(#448)。
            antigravityStatus: .unavailable(.notOfferedByConnectionMethod),
            sendWhenDone: (connection as? any SendWhenDoneHosting).map { .available($0) } ?? .unavailable(.connectionLacksSupport),
            pushInstaller: (connection as? any PushPluginInstallerProviding)?.pushPluginInstallers().map { make in
                .available { $0.installer(make) }
            } ?? .unavailable(.connectionLacksSupport),
            pushTestSender: https.map { https in
                .available { HostServicePushTestSender(service: $0, connection: https, hostName: name) }
            } ?? .unavailable(.connectionLacksSupport),
            hostServiceConnection: https.map { .available($0) } ?? .unavailable(.connectionLacksSupport),
            consent: environment.consent)
    }

    @discardableResult
    func drop(_ id: UUID) -> Task<Void, Never>? {
        guard let connection = connections.removeValue(forKey: id) else { return nil }
        return Task { await connection.disconnect() }
    }

    func disconnectors() -> [@Sendable () async -> Void] {
        connections.values.map { connection in { await connection.disconnect() } }
    }

    func prewarmers() -> [@Sendable () async -> Void] {
        // 讀主機服務版本會撥號並完成 hello 握手。
        connections.values.map { connection in { _ = try? await connection.hostServiceVersion() } }
    }

    /// 先刪推播配對再撤銷權杖(主機離線時權杖留在主機上,可在主機上撤銷);臨時連線用讀出的權杖。
    func cleanUpAfterRemoval(_ removal: HostRemoval) {
        guard case .https(let address) = removal.configuration.connection, let deviceToken = removal.deviceToken else { return }
        let host = removal.configuration
        let pairing = environment.hostService.pairing
        let recorder = environment.traffic.recorder(for: host.id)
        guard let pushService = environment.pushService, pushService.store.keyHash(forHost: host.id.uuidString) != nil,
            let connection = environment.hostService.makeConnection(address, { deviceToken }) as? HTTPSHostConnection
        else {
            environment.hostService.revokeWithoutWaiting(deviceToken, at: address, traffic: recorder)
            return
        }
        connection.attachTraffic(recorder)
        pushService.forget(hostID: host.id.uuidString, installer: pushService.hostServiceInstaller(connection: connection)) {
            await connection.disconnect()
            try? await pairing.revoke(address: address, deviceToken: deviceToken, traffic: recorder)
        }
    }
}

// MARK: - Demo(Demo 主機與示範主機)

@MainActor
final class DemoHostAdapter {
    private let demoChannel: any HostChannel
    private let demoFiles: any HostFileFetching
    private let consent: any HostWriteConsentStore

    init(channel: any HostChannel, files: any HostFileFetching, consent: any HostWriteConsentStore) {
        demoChannel = channel
        demoFiles = files
        self.consent = consent
    }

    var channel: any HostChannel { demoChannel }

    /// Demo 主機:自己的取檔,沒有真的測試通知。
    func demoHostCapabilities() -> HostCapabilities {
        ChannelCapabilities.make(channel: demoChannel, herdr: HerdrInstallation(), files: demoFiles, hostName: nil, consent: consent)
            .markingDemo()
    }

    /// 示範主機(Studio Mac、Build Box):各自的通道。
    func companionCapabilities(channel: any HostChannel) -> HostCapabilities {
        ChannelCapabilities.make(channel: channel, herdr: HerdrInstallation(), hostName: nil, consent: consent).markingDemo()
    }
}

extension HostCapabilities {
    /// Demo 的「沒有」是因為沒有真的後端,不是連線方式做不到。
    fileprivate func markingDemo() -> HostCapabilities {
        var copy = self
        copy.sendWhenDone = .unavailable(.demoHost)
        copy.hostServiceConnection = .unavailable(.demoHost)
        return copy
    }
}
