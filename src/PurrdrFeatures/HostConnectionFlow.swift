import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

/// 連線流程所在的階段(從主機編輯頁抽出，#340)。
public enum HostConnectionPhase: Equatable {
    case editing
    case testing
    /// 第一次連到這台主機:請使用者確認主機身分(TOFU)。
    case confirmHostKey(HostKeyFingerprint)
    /// 主機出示的 key 與已存的不同。
    case hostKeyChanged(presented: HostKeyFingerprint, pinned: HostKeyFingerprint)
    /// 主機的 herdr 低於 0.9.5,可在確認後更新。
    case needsUpdate(HerdrVersion)
    case updating
    /// herdr 已更新，但執行中的伺服器還是舊版(Windows 沒有 live handoff):請使用者在主機上重啟伺服器再測試。
    case restartServerRequired
    case tested(HostProbeReport)
    /// HTTPS 主機：配對(或用存著的權杖)後連上主機服務。
    case connected(HostServiceCheck)
    case failed(String)
}

/// HTTPS 主機的連線測試結果。
public struct HostServiceCheck: Equatable, Sendable {
    public var herdrVersion: String
    public var agentCount: Int
    /// 這次配對成唯讀;用存著的權杖測試時不知道(`nil`)。
    public var readOnly: Bool?
}

/// SSH 主機的草稿：pin 是這次流程中信任的指紋。
package struct SSHConnectionDraft: Equatable {
    package var settings: HostConfiguration.SSHSettings
    /// OpenSSH 的登入方式;Tailscale SSH 為 `nil`。
    package var authentication: HostConfiguration.OpenSSHAuthentication?
    /// 這次輸入的祕密;`nil` = 不需要或沿用已存的。
    package var secret: HostSecret?

    package init(
        settings: HostConfiguration.SSHSettings, authentication: HostConfiguration.OpenSSHAuthentication? = nil, secret: HostSecret? = nil
    ) {
        self.settings = settings
        self.authentication = authentication
        self.secret = secret
    }

    package var method: HostConfiguration.ConnectionMethod { authentication == nil ? .tailscaleSSH : .openSSH }

    package var connection: HostConfiguration.Connection {
        authentication.map { .openSSH(settings, authentication: $0) } ?? .tailscaleSSH(settings)
    }
}

/// 要測試與儲存的一台主機(名稱加連線設定)。
package struct HostConnectionDraft: Equatable {
    package enum Connection: Equatable {
        case ssh(SSHConnectionDraft)
        /// 配對碼 `nil` = 沿用存著的權杖。
        case https(HostServiceAddress, pairingCode: String?)

        /// 與已存主機的設定相同(不看 host key pin 與祕密)。
        package func sameSettings(as saved: HostConfiguration.Connection) -> Bool {
            switch self {
            case .ssh(let ssh):
                ssh.settings.endpoint == saved.ssh?.endpoint && ssh.settings.herdr == saved.ssh?.herdr
                    && ssh.authentication == saved.authentication
            case .https(let address, _):
                address == saved.hostService
            }
        }
    }

    package var name: String
    package var connection: Connection

    package init(name: String, connection: Connection) {
        self.name = name
        self.connection = connection
    }
}

/// 連線測試、主機身分確認、herdr 版本檢查與儲存(權杖、Keychain)。主機編輯頁與新增主機引導共用(#340)。
///
/// 流程不知道欄位長什麼樣：呼叫端把目前的草稿交進來。測試後草稿有任何不同就不能儲存。
/// 第一次連線先讓使用者確認主機身分，確認後才登入;指紋改變時阻擋、不能略過。
@MainActor
@Observable
package final class HostConnectionFlow {
    package var phase: HostConnectionPhase = .editing

    @ObservationIgnored private let store: any HostStore
    @ObservationIgnored private let existing: HostConfiguration?
    @ObservationIgnored private let credentials: HostCredentials
    @ObservationIgnored private let hostService: HostServiceAccess
    @ObservationIgnored private let makeChannel:
        @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    /// 新主機在流程開始時就決定 id:同意(以主機 id 記)要對得上儲存後的主機。
    @ObservationIgnored package let hostID: UUID
    /// 這次流程中使用者確認過的指紋，以及它屬於哪個端點。
    @ObservationIgnored package var accepted: (fingerprint: HostKeyFingerprint, endpoint: SSHEndpoint)?
    @ObservationIgnored private var tested: (draft: HostConnectionDraft, operatingSystem: HostOperatingSystem?)?
    /// 這次流程中配對拿到的權杖(配對碼只能用一次，再測沿用)。
    @ObservationIgnored private var pairing: Pairing?
    @ObservationIgnored package private(set) var attempt = 0

    /// 數據用量(#353):依這台主機的 id 取得計量入口;連線測試、更新 herdr、配對與撤銷的流量記在即將儲存(或已存)的這台主機底下。
    @ObservationIgnored package var traffic: ((UUID) -> TrafficRecording)?
    private var recorder: TrafficRecording? { traffic?(hostID) }

    private func metered(_ channel: any HostChannel) -> any HostChannel {
        (channel as? SSHHostChannel)?.attachTraffic(recorder)
        return channel
    }

    package init(
        store: any HostStore, existing: HostConfiguration? = nil, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        self.existing = existing
        self.credentials = credentials
        self.hostService = hostService
        self.makeChannel = makeChannel
        hostID = existing?.id ?? UUID()
    }

    // MARK: - 狀態

    /// 最近一次測試成功，而且之後沒有改過任何欄位。
    package func canSave(_ draft: HostConnectionDraft?) -> Bool {
        guard let tested, let draft else { return false }
        switch phase {
        case .tested, .connected: return tested.draft == draft
        default: return false
        }
    }

    /// 測試時偵測到的主機作業系統。
    package var testedOperatingSystem: HostOperatingSystem? { tested?.operatingSystem }

    /// 重新開始一次進行中的動作(測試、加入公鑰);之前還在跑的結果不算。回傳這次的編號。
    package func beginAttempt() -> Int {
        attempt += 1
        return attempt
    }

    /// 這個動作是不是仍是最新的一次。
    package func isCurrent(_ attempt: Int) -> Bool { attempt == self.attempt }

    // MARK: - 動作

    /// 連線測試：主機 OS、herdr 版本、snapshot、agent 整合。
    package func test(_ draft: HostConnectionDraft) async {
        guard case .ssh(let ssh) = draft.connection else { return await testHostService(draft) }
        let current = beginAttempt()
        phase = .testing
        let channel = metered(makeChannel(ssh.settings.endpoint, ssh.settings.hostKeyPin, credential(for: ssh)))
        let result: Result<HostProbeReport, any Error>
        do {
            result = .success(try await HostProbe(channel: channel, herdr: ssh.settings.herdr).run())
        } catch {
            result = .failure(error)
        }
        await channel.disconnect()
        // 測試期間使用者取消或又按了一次：舊的結果不算。
        guard current == attempt else { return }
        switch result {
        case .success(let report):
            tested = (draft, report.operatingSystem)
            phase = .tested(report)
        case .failure(SSHConnectionError.hostKeyUnverified(let presented)):
            // Tailscale SSH 的身分已由 tailnet 確認:第一次連線自動記住出示的 key(仍 pin),不問使用者。
            // 只在還沒有 pin 時才會走到這裡;key 之後變了仍是 `hostKeyChanged`,照舊擋下。
            if ssh.method == .tailscaleSSH, ssh.settings.hostKeyPin == nil {
                accepted = (presented, ssh.settings.endpoint)
                var remembered = ssh
                remembered.settings.hostKeyPin = presented
                return await test(HostConnectionDraft(name: draft.name, connection: .ssh(remembered)))
            }
            phase = .confirmHostKey(presented)
        case .failure(SSHConnectionError.hostKeyChanged(let presented, let pinned)):
            phase = .hostKeyChanged(presented: presented, pinned: pinned)
        case .failure(HostProbeError.herdrOutdated(let version)):
            phase = .needsUpdate(version)
        case .failure(let error):
            phase = .failed(HostErrorText.message(for: error, connection: ssh.method, authentication: ssh.authentication))
        }
    }

    /// HTTPS 主機：有配對碼就先配對換權杖(同一個配對碼只換一次),沒有就用存著的權杖;再連上主機服務讀一次 Agent 列表。
    private func testHostService(_ draft: HostConnectionDraft) async {
        guard case .https(let address, let pairingCode) = draft.connection else { return }
        let current = beginAttempt()
        phase = .testing
        let result: Result<HostServiceCheck, any Error>
        do {
            let testToken = try await deviceToken(address: address, pairingCode: pairingCode)
            let connection = hostService.makeConnection(address) { testToken.deviceToken }
            (connection as? HTTPSHostConnection)?.attachTraffic(recorder)
            let snapshot: HostSnapshot
            do {
                snapshot = try await HerdrClient(connection: connection).snapshot()
                await connection.disconnect()
            } catch {
                await connection.disconnect()
                throw error
            }
            // 與 SSH 的連線測試相同的最低版本;主機服務不代為更新，請使用者在主機上更新。
            if let version = HerdrVersion(snapshot.version), version < .minimumSupported { throw HostProbeError.herdrOutdated(version) }
            result = .success(HostServiceCheck(
                herdrVersion: snapshot.version, agentCount: snapshot.agents.count, readOnly: testToken.readOnly))
        } catch {
            result = .failure(error)
        }
        guard current == attempt else { return }
        switch result {
        case .success(let check):
            tested = (draft, nil)
            phase = .connected(check)
        case .failure(HostProbeError.herdrOutdated(let version)):
            phase = .needsUpdate(version)
        case .failure(let error):
            phase = .failed(HostErrorText.message(for: error, connection: .https))
        }
    }

    /// 測試用的權杖：這次的配對碼換得的，或已存主機的。換了位址或配對碼重新配對時，前一次拿到的權杖請主機撤銷。
    private func deviceToken(address: HostServiceAddress, pairingCode: String?) async throws -> TestToken {
        guard let code = pairingCode else {
            guard let existing, let token = try hostService.tokens.deviceToken(for: existing.id) else { throw HostServiceError.notPaired }
            return TestToken(deviceToken: token, readOnly: nil)
        }
        if let pairing, pairing.address == address, pairing.code == code {
            return TestToken(deviceToken: pairing.device.deviceToken, readOnly: pairing.device.readOnly)
        }
        let device = try await hostService.pairing.pair(
            address: address, pairingCode: code, deviceName: hostService.deviceName, traffic: recorder)
        discardUnsavedPairing()
        pairing = Pairing(address: address, code: code, device: device)
        return TestToken(deviceToken: device.deviceToken, readOnly: device.readOnly)
    }

    /// 配對拿到的權杖沒存下來(取消、離開流程):請主機撤銷，主機不留沒用的權杖。
    package func discardUnsavedPairing() {
        guard let pairing, !pairing.isSaved else { return }
        self.pairing = nil
        hostService.revokeWithoutWaiting(pairing.device.deviceToken, at: pairing.address, traffic: recorder)
    }

    /// 取消進行中的測試。
    package func cancelTest() {
        attempt += 1
        phase = .editing
    }

    /// 目前停在主機身分確認(或指紋變了)時，出示的那一把 key。
    package var presentedHostKey: HostKeyFingerprint? {
        switch phase {
        case .confirmHostKey(let fingerprint), .hostKeyChanged(let fingerprint, _): fingerprint
        default: nil
        }
    }

    /// 匯入的分享連結附了 host key 指紋:視為已確認,連線測試只接受那一把(主機出示別的 key 時一樣阻擋)。
    package func acceptSharedPin(of shared: SharedHost) {
        if let pin = shared.hostKeyPin { accepted = (pin, shared.endpoint) }
    }

    /// 信任主機剛剛出示的那一把 key,記在這次流程裡(呼叫端接著重新測試)。
    /// 只有第一次連線(`confirmHostKey`)能信任;指紋變了(`hostKeyChanged`)一律不行、不能一鍵略過。
    /// 永遠不清空 pin 然後信任下一個回應者(行為規格 §8.2)。沒有待確認的 key 或不是 SSH 時回 `false`。
    @discardableResult
    package func trustPresentedHostKey(for draft: HostConnectionDraft) -> Bool {
        guard case .ssh(let ssh) = draft.connection, case .confirmHostKey(let presented) = phase else { return false }
        accepted = (presented, ssh.settings.endpoint)
        return true
    }

    /// 使用者確認後在主機上更新 herdr(macOS／Linux 是 `herdr update --handoff`);回傳是否可以馬上重測。
    /// Windows 的伺服器不會交接到新版：先請使用者在主機上重啟伺服器，不馬上重測(重測只會再看到舊版)。
    package func updateHerdr(_ draft: HostConnectionDraft) async -> Bool {
        guard case .ssh(let ssh) = draft.connection, case .needsUpdate = phase else { return false }
        phase = .updating
        let channel = metered(makeChannel(ssh.settings.endpoint, ssh.settings.hostKeyPin, credential(for: ssh)))
        let outcome: HerdrUpdateOutcome
        do {
            outcome = try await HostProbe(channel: channel, herdr: ssh.settings.herdr).updateHerdr()
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            phase = .failed(HostErrorText.message(for: error, connection: ssh.method, authentication: ssh.authentication))
            return false
        }
        guard outcome == .handedOff else {
            phase = .restartServerRequired
            return false
        }
        return true
    }

    /// 儲存。測試沒通過或之後改過欄位就不存;寫入失敗時留在流程並說明原因。
    ///
    /// 祕密先寫(寫不進 Keychain 就什麼都不存),再存主機設定;不再需要的祕密刪掉。
    package func save(_ draft: HostConnectionDraft?) -> HostConfiguration? {
        guard canSave(draft), let tested else { return nil }
        let id = hostID
        if case .https(let address, let pairingCode) = tested.draft.connection {
            return saveHostService(HostConfiguration(id: id, name: tested.draft.name, hostService: address), pairingCode: pairingCode)
        }
        guard case .ssh(let ssh) = tested.draft.connection else { return nil }
        let host = HostConfiguration(id: id, name: tested.draft.name, connection: ssh.connection, operatingSystem: tested.operatingSystem)
        let wroteSecret: Bool
        do {
            if let secret = ssh.secret {
                try credentials.secrets.setSecret(secret, for: host.id)
                wroteSecret = true
            } else {
                if existing != nil, ssh.authentication == nil || ssh.authentication == .deviceKey {
                    try credentials.secrets.setSecret(nil, for: host.id)
                }
                wroteSecret = false
            }
        } catch {
            phase = .failed(String(localized: "Couldn’t save this host’s sign-in details on this device. \(error.localizedDescription)"))
            return nil
        }
        do {
            try store.save(host)
            return host
        } catch {
            // 新主機沒存成：不要留下沒有主機的祕密。
            if wroteSecret, existing == nil { try? credentials.secrets.setSecret(nil, for: host.id) }
            phase = .failed(String(localized: "Couldn’t save this host on this device. \(error.localizedDescription)"))
            return nil
        }
    }

    /// HTTPS 主機：新配對的權杖先寫(寫不進 Keychain 就什麼都不存),再存主機設定;SSH 的祕密不再需要，刪掉。
    private func saveHostService(_ host: HostConfiguration, pairingCode: String?) -> HostConfiguration? {
        let newToken = pairingCode == nil ? nil : pairing?.device.deviceToken
        let previousToken = try? hostService.tokens.deviceToken(for: host.id)
        do {
            if let newToken { try hostService.tokens.setDeviceToken(newToken, for: host.id) }
            if existing != nil { try credentials.secrets.setSecret(nil, for: host.id) }
        } catch {
            phase = .failed(String(localized: "Couldn’t save this host’s pairing on this device. \(error.localizedDescription)"))
            return nil
        }
        do {
            try store.save(host)
        } catch {
            if newToken != nil { try? hostService.tokens.setDeviceToken(previousToken, for: host.id) }
            phase = .failed(String(localized: "Couldn’t save this host on this device. \(error.localizedDescription)"))
            return nil
        }
        if newToken != nil { pairing?.isSaved = true }
        // 重新配對換了權杖：舊的請主機撤銷。
        if let newToken, let previousToken, previousToken != newToken, let previousAddress = existing?.hostService {
            hostService.revokeWithoutWaiting(previousToken, at: previousAddress)
        }
        return host
    }

    // MARK: - 內部

    /// 開通道用的憑證來源(給需要自己開通道的流程，例如加入公鑰)。
    package func openChannel(for ssh: SSHConnectionDraft, credential: @escaping SSHCredentialProvider) -> any HostChannel {
        metered(makeChannel(ssh.settings.endpoint, ssh.settings.hostKeyPin, credential))
    }

    private func credential(for ssh: SSHConnectionDraft) -> SSHCredentialProvider {
        credentials.provider(
            method: ssh.method, authentication: ssh.authentication, hostID: ssh.secret == nil ? existing?.id : nil, entered: ssh.secret)
    }

    /// 只有主機或埠改變(或新主機)才重設 pin;改名稱、使用者、herdr 設定不重設(行為規格 §8.2)。
    package func pin(for endpoint: SSHEndpoint) -> HostKeyFingerprint? {
        if let accepted, Self.sameMachine(accepted.endpoint, endpoint) { return accepted.fingerprint }
        if let saved = existing?.ssh, Self.sameMachine(saved.endpoint, endpoint) { return saved.hostKeyPin }
        return nil
    }

    private static func sameMachine(_ lhs: SSHEndpoint, _ rhs: SSHEndpoint) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }

    /// 這次流程中以配對碼換得的權杖。
    private struct Pairing {
        var address: HostServiceAddress
        var code: String
        var device: PairedDevice
        /// 已存成主機的權杖(不再撤銷)。
        var isSaved = false
    }

    /// 連線測試用的權杖;用存著的權杖時不知道是否唯讀(`nil`)。
    private struct TestToken {
        var deviceToken: String
        var readOnly: Bool?
    }
}
