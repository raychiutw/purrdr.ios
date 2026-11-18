import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH

/// 主機的儲存。正式實作是 `KeychainHostStore`(主機設定與 pin 存 Keychain,僅本裝置、解鎖後)。
@MainActor
public protocol HostStore: AnyObject {
    func loadHosts() throws -> [HostConfiguration]
    func save(_ host: HostConfiguration) throws
    func delete(_ id: UUID) throws
}

/// 新增／編輯主機畫面的 model(行為規格 F1.2、§8.1–8.3)。
///
/// 儲存前必須通過一次連線測試;測試後改了任何欄位都要重測。第一次連線先讓使用者確認 host key 指紋，
/// 確認後才登入;指紋改變時阻擋。測試用暫時連線，測完即拆。
///
/// OpenSSH 主機可用這支裝置的金鑰(Secure Enclave)、匯入的私鑰或密碼登入。祕密欄位在編輯既有主機時
/// 留空 = 保留原本的;祕密與主機設定分開存。
@MainActor
@Observable
public final class HostEditorModel {
    public enum Phase: Equatable {
        case editing
        case testing
        /// 第一次連到這台主機:請使用者確認指紋(TOFU)。
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

    /// 匯入私鑰的檢查結果。
    public enum KeyCheck: Equatable, Sendable {
        /// 沒有貼上私鑰。
        case empty
        /// 還沒檢查目前的內容(或檢查中)。
        case unchecked
        case valid(SSHPublicKey)
        case invalid(SSHKeyImportError)
    }

    public var name = ""
    public var address = ""
    public var port = "22"
    public var username = ""
    /// 空白為 `herdr`。
    public var herdrPath = ""
    /// 空白為預設 session。
    public var herdrSession = ""
    public var connectionMethod: HostConfiguration.ConnectionMethod = .tailscaleSSH
    /// OpenSSH 的登入方式。預設用這支裝置的金鑰。
    public var authentication: HostConfiguration.OpenSSHAuthentication = .deviceKey
    /// 編輯既有主機時留空 = 保留原本的密碼。
    public var password = ""
    /// 貼上的 OpenSSH 私鑰。編輯既有主機時留空 = 保留原本的金鑰。
    public var privateKeyText = ""
    /// HTTPS 主機的配對碼(主機配對指令顯示的)。編輯已配對的主機時留空 = 沿用存著的裝置權杖。
    public var pairingCode = ""
    public private(set) var phase: Phase = .editing
    /// 這支裝置的公鑰(含註解),`loadDeviceKey()` 之後才有。
    public private(set) var devicePublicKey: SSHPublicKey?
    /// 拿不到裝置金鑰時的說明。
    public private(set) var deviceKeyProblem: String?

    /// 是否是編輯既有主機。
    public var isEditing: Bool { existing != nil }

    /// HTTPS 主機要輸入配對碼：新主機，或這支裝置還沒有它的裝置權杖(例如主機同步帶來的)。
    public var needsPairingCode: Bool { connectionMethod == .https && !hasStoredDeviceToken }

    private let store: any HostStore
    private let existing: HostConfiguration?
    private let credentials: HostCredentials
    private let hostService: HostServiceAccess
    /// 編輯的 HTTPS 主機在這支裝置已有裝置權杖。
    private let hasStoredDeviceToken: Bool
    /// 這次編輯中配對拿到的權杖(配對碼只能用一次，再測沿用)。
    private var paired: (address: HostServiceAddress, code: String, device: PairedDevice)?
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    /// 最近一次檢查的私鑰輸入與結果。
    private var checked: (input: HostSecret, result: KeyCheck)?
    /// 這次編輯中使用者確認過的指紋，以及它屬於哪個端點。
    private var accepted: (fingerprint: HostKeyFingerprint, endpoint: SSHEndpoint)?
    private var tested: (draft: Draft, operatingSystem: HostOperatingSystem?)?
    private var attempt = 0

    public init(
        store: any HostStore, editing: HostConfiguration? = nil, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        existing = editing
        self.credentials = credentials
        self.hostService = hostService
        self.makeChannel = makeChannel
        hasStoredDeviceToken = editing.map { $0.connectionMethod == .https && (try? hostService.tokens.deviceToken(for: $0.id)) != nil }
            ?? false
        if let editing {
            name = editing.name
            address = editing.hostService?.description ?? editing.endpoint.host
            port = String(editing.endpoint.port)
            username = editing.endpoint.username
            herdrPath = editing.herdr.path == "herdr" ? "" : editing.herdr.path
            herdrSession = editing.herdr.session ?? ""
            connectionMethod = editing.connectionMethod
            authentication = editing.authentication ?? .deviceKey
        }
    }

    /// 從主機分享連結匯入：新主機，欄位帶入分享內容。分享內容附的 host key 指紋視為已確認，
    /// 所以連線測試只接受那一把 key(主機出示別的 key 時一樣阻擋);仍要測試通過才能儲存。
    public convenience init(
        store: any HostStore, importing shared: SharedHost, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.init(store: store, editing: nil, credentials: credentials, hostService: hostService, makeChannel: makeChannel)
        name = shared.name
        address = shared.hostService?.description ?? shared.endpoint.host
        port = String(shared.endpoint.port)
        username = shared.endpoint.username
        herdrPath = shared.herdr.path == "herdr" ? "" : shared.herdr.path
        herdrSession = shared.herdr.session ?? ""
        connectionMethod = shared.connectionMethod
        if let pin = shared.hostKeyPin { accepted = (pin, shared.endpoint) }
    }

    /// 從主機配對指令的 QR code(`purrdr://pair?…`)新增 HTTPS 主機：帶入位址與配對碼，名稱預設是主機名稱的第一段。
    public convenience init(
        store: any HostStore, pairing link: HostServicePairingLink, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.init(store: store, editing: nil, credentials: credentials, hostService: hostService, makeChannel: makeChannel)
        connectionMethod = .https
        address = link.address.description
        pairingCode = link.pairingCode
        name = link.address.hostName.split(separator: ".").first.map(String.init) ?? link.address.hostName
    }

    // MARK: - 狀態

    public var canTest: Bool { draft != nil && phase != .testing && phase != .updating }

    /// 最近一次測試成功，而且之後沒有改過任何欄位。
    public var canSave: Bool {
        guard let tested else { return false }
        switch phase {
        case .tested, .connected: return tested.draft == draft
        default: return false
        }
    }

    /// 有沒有未儲存的變更(按取消時要確認放棄)。
    public var hasChanges: Bool {
        let secretsEntered = !(password.isEmpty && privateKeyText.isEmpty && pairingCode.isEmpty)
        guard let existing else {
            return secretsEntered || !(name.isEmpty && address.isEmpty && username.isEmpty && herdrPath.isEmpty && herdrSession.isEmpty)
        }
        return secretsEntered || draft?.endpoint != existing.endpoint || draft?.name != existing.name || draft?.herdr != existing.herdr
            || connectionMethod != existing.connectionMethod || selectedAuthentication != existing.authentication
    }

    /// 匯入私鑰的檢查結果(只看目前的內容)。
    public var keyCheck: KeyCheck {
        guard authentication == .importedKey, let entered = enteredSecret else { return .empty }
        guard let checked, checked.input == entered else { return .unchecked }
        return checked.result
    }

    /// 編輯既有主機、登入方式沒變時，可以不重新輸入祕密。
    public var hasStoredSecret: Bool {
        existing?.connectionMethod == .openSSH && existing?.authentication == authentication && authentication != .deviceKey
    }

    /// 目前信任的指紋(已存或剛確認)。顯示用。
    public var hostKeyFingerprint: HostKeyFingerprint? { draft.flatMap(pin(for:)) }

    // MARK: - 動作

    /// 連線測試：主機 OS、herdr 版本、snapshot、agent 整合。
    public func test() async {
        guard let draft else { return }
        if let address = draft.hostService { return await testHostService(draft, address: address) }
        attempt += 1
        let current = attempt
        phase = .testing
        let pin = pin(for: draft)
        let channel = makeChannel(draft.endpoint, pin, credential(for: draft))
        let result: Result<HostProbeReport, any Error>
        do {
            result = .success(try await HostProbe(channel: channel, herdr: draft.herdr).run())
        } catch {
            result = .failure(error)
        }
        await channel.disconnect()
        // 測試期間使用者取消或又按了一次：舊的結果不算。
        guard current == attempt else { return }
        switch result {
        case .success(let report):
            tested = (Draft(draft, pin: pin), report.operatingSystem)
            phase = .tested(report)
        case .failure(SSHConnectionError.hostKeyUnverified(let presented)):
            phase = .confirmHostKey(presented)
        case .failure(SSHConnectionError.hostKeyChanged(let presented, let pinned)):
            phase = .hostKeyChanged(presented: presented, pinned: pinned)
        case .failure(HostProbeError.herdrOutdated(let version)):
            phase = .needsUpdate(version)
        case .failure(let error):
            phase = .failed(HostErrorText.message(for: error, connection: draft.connectionMethod, authentication: draft.authentication))
        }
    }

    /// HTTPS 主機：有配對碼就先配對換權杖(同一個配對碼只換一次),沒有就用存著的權杖;再連上主機服務讀一次 Agent 列表。
    private func testHostService(_ draft: Draft, address: HostServiceAddress) async {
        attempt += 1
        let current = attempt
        phase = .testing
        let result: Result<HostServiceCheck, any Error>
        do {
            let (token, readOnly) = try await deviceToken(for: draft, address: address)
            let connection = hostService.makeConnection(address) { token }
            let snapshot: HostSnapshot
            do {
                snapshot = try await HerdrClient(connection: connection).snapshot()
                await connection.disconnect()
            } catch {
                await connection.disconnect()
                throw error
            }
            result = .success(HostServiceCheck(herdrVersion: snapshot.version, agentCount: snapshot.agents.count, readOnly: readOnly))
        } catch {
            result = .failure(error)
        }
        guard current == attempt else { return }
        switch result {
        case .success(let check):
            tested = (draft, nil)
            phase = .connected(check)
        case .failure(let error):
            phase = .failed(HostErrorText.message(for: error, connection: .https))
        }
    }

    /// 測試用的權杖：這次的配對碼換得的，或已存主機的。
    private func deviceToken(for draft: Draft, address: HostServiceAddress) async throws -> (String, Bool?) {
        guard let code = draft.pairingCode else {
            guard let existing, let token = try hostService.tokens.deviceToken(for: existing.id) else { throw HostServiceError.notPaired }
            return (token, nil)
        }
        if let paired, paired.address == address, paired.code == code { return (paired.device.deviceToken, paired.device.readOnly) }
        let device = try await hostService.pairing.pair(address: address, pairingCode: code, deviceName: hostService.deviceName)
        paired = (address, code, device)
        return (device.deviceToken, device.readOnly)
    }

    /// 檢查貼上的私鑰(格式、種類、有沒有 passphrase)。在背景做，不卡住打字。
    public func checkKey() async {
        guard authentication == .importedKey, let entered = enteredSecret, case .privateKey(let text, _) = entered,
              checked?.input != entered else { return }
        let result = await Task.detached { () -> KeyCheck in
            do throws(SSHKeyImportError) {
                return KeyCheck.valid(try SSHPrivateKey(openSSH: text).publicKey)
            } catch {
                return KeyCheck.invalid(error)
            }
        }.value
        checked = (entered, result)
    }

    /// 匯入的金鑰不能用(例如 RSA):改用這支裝置的金鑰，並清掉貼上的私鑰。
    public func useDeviceKeyInstead() {
        authentication = .deviceKey
        privateKeyText = ""
    }

    /// 取得這支裝置的公鑰(第一次會在 Secure Enclave 產生金鑰)。
    public func loadDeviceKey() async {
        guard devicePublicKey == nil else { return }
        let deviceKey = credentials.deviceKey
        let result = await Task.detached { Result { try deviceKey.publicKey() } }.value
        switch result {
        case .success(let key):
            devicePublicKey = key
            deviceKeyProblem = nil
        case .failure(let error):
            deviceKeyProblem = HostErrorText.message(for: error)
        }
    }

    /// 取消進行中的測試。
    public func cancelTest() {
        attempt += 1
        phase = .editing
    }

    /// 信任主機剛剛出示的那一把 key,再重新測試。永遠不清空 pin 然後信任下一個回應者(行為規格 §8.2)。
    public func trustPresentedHostKey() async {
        guard let draft else { return }
        let presented: HostKeyFingerprint
        switch phase {
        case .confirmHostKey(let fingerprint), .hostKeyChanged(let fingerprint, _): presented = fingerprint
        default: return
        }
        accepted = (presented, draft.endpoint)
        await test()
    }

    /// 不信任、不更新：回到編輯。
    public func dismissPrompt() {
        phase = .editing
    }

    /// 使用者確認後在主機上更新 herdr(macOS／Linux 是 `herdr update --handoff`),再重新測試。
    /// Windows 的伺服器不會交接到新版：先請使用者在主機上重啟伺服器，不馬上重測(重測只會再看到舊版)。
    public func updateHerdr() async {
        guard let draft, case .needsUpdate = phase else { return }
        phase = .updating
        let channel = makeChannel(draft.endpoint, pin(for: draft), credential(for: draft))
        let outcome: HerdrUpdateOutcome
        do {
            outcome = try await HostProbe(channel: channel, herdr: draft.herdr).updateHerdr()
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            phase = .failed(HostErrorText.message(for: error, connection: draft.connectionMethod, authentication: draft.authentication))
            return
        }
        guard outcome == .handedOff else {
            phase = .restartServerRequired
            return
        }
        await test()
    }

    /// 儲存。測試沒通過或之後改過欄位就不存;寫入失敗時留在編輯器並說明原因。
    ///
    /// 祕密先寫(寫不進 Keychain 就什麼都不存),再存主機設定;不再需要的祕密刪掉。
    @discardableResult
    public func save() -> HostConfiguration? {
        guard canSave, let tested else { return nil }
        let draft = tested.draft
        if let address = draft.hostService { return saveHostService(draft, address: address) }
        let host = HostConfiguration(
            id: existing?.id ?? UUID(), name: draft.name, endpoint: draft.endpoint, connectionMethod: draft.connectionMethod,
            authentication: draft.authentication, herdr: draft.herdr, operatingSystem: tested.operatingSystem,
            hostKeyPin: draft.pin)
        let wroteSecret: Bool
        do {
            if let secret = draft.secret {
                try credentials.secrets.setSecret(secret, for: host.id)
                wroteSecret = true
            } else {
                if existing != nil, draft.authentication == nil || draft.authentication == .deviceKey {
                    try credentials.secrets.setSecret(nil, for: host.id)
                }
                wroteSecret = false
            }
        } catch {
            phase = .failed(String(localized: "Couldn’t save this host’s password or key on this device. \(error.localizedDescription)"))
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
    private func saveHostService(_ draft: Draft, address: HostServiceAddress) -> HostConfiguration? {
        let host = HostConfiguration(id: existing?.id ?? UUID(), name: draft.name, hostService: address)
        let newToken = draft.pairingCode == nil ? nil : paired?.device.deviceToken
        let previousToken = try? hostService.tokens.deviceToken(for: host.id)
        do {
            if let newToken { try hostService.tokens.setDeviceToken(newToken, for: host.id) }
            if existing != nil { try credentials.secrets.setSecret(nil, for: host.id) }
        } catch {
            phase = .failed(String(localized: "Couldn’t save this host’s device token on this device. \(error.localizedDescription)"))
            return nil
        }
        do {
            try store.save(host)
        } catch {
            if newToken != nil { try? hostService.tokens.setDeviceToken(previousToken, for: host.id) }
            phase = .failed(String(localized: "Couldn’t save this host on this device. \(error.localizedDescription)"))
            return nil
        }
        // 重新配對換了權杖：舊的請主機撤銷(失敗也不影響，舊權杖可在主機上撤銷)。
        if let newToken, let previousToken, previousToken != newToken, let previousAddress = existing?.hostService {
            let pairing = hostService.pairing
            Task { try? await pairing.revoke(address: previousAddress, deviceToken: previousToken) }
        }
        return host
    }

    // MARK: - 內部

    private struct Draft: Equatable {
        var name: String
        var endpoint: SSHEndpoint
        var herdr: HerdrInstallation
        var connectionMethod: HostConfiguration.ConnectionMethod
        var authentication: HostConfiguration.OpenSSHAuthentication?
        /// 這次輸入的祕密;`nil` = 不需要或沿用已存的。
        var secret: HostSecret?
        var pin: HostKeyFingerprint?
        /// HTTPS 主機的主機服務位址與配對碼(`nil` = 沿用存著的權杖)。
        var hostService: HostServiceAddress?
        var pairingCode: String?

        init(_ draft: Draft, pin: HostKeyFingerprint?) {
            self = draft
            self.pin = pin
        }

        init(
            name: String, endpoint: SSHEndpoint, herdr: HerdrInstallation, connectionMethod: HostConfiguration.ConnectionMethod,
            authentication: HostConfiguration.OpenSSHAuthentication?, secret: HostSecret?
        ) {
            self.name = name
            self.endpoint = endpoint
            self.herdr = herdr
            self.connectionMethod = connectionMethod
            self.authentication = authentication
            self.secret = secret
        }
    }

    /// OpenSSH 時的登入方式;Tailscale SSH 為 `nil`。
    private var selectedAuthentication: HostConfiguration.OpenSSHAuthentication? {
        connectionMethod == .openSSH ? authentication : nil
    }

    /// 這次輸入的祕密(沒輸入為 `nil`)。
    private var enteredSecret: HostSecret? {
        switch selectedAuthentication {
        case .password?:
            password.isEmpty ? nil : .password(password)
        case .importedKey?:
            privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : .privateKey(privateKeyText, passphrase: nil)
        case .deviceKey?, nil:
            nil
        }
    }

    /// 祕密是否齊全：需要祕密的方式要有輸入(匯入的私鑰要檢查通過)或沿用已存的。
    private var hasUsableSecret: Bool {
        switch selectedAuthentication {
        case .password?:
            enteredSecret != nil || hasStoredSecret
        case .importedKey?:
            enteredSecret == nil ? hasStoredSecret : keyCheck.isValid
        case .deviceKey?, nil:
            true
        }
    }

    private func credential(for draft: Draft) -> SSHCredentialProvider {
        credentials.provider(
            method: draft.connectionMethod, authentication: draft.authentication,
            hostID: draft.secret == nil ? existing?.id : nil, entered: draft.secret)
    }

    private var draft: Draft? {
        if connectionMethod == .https { return hostServiceDraft }
        let name = name.trimmingCharacters(in: .whitespaces)
        let address = address.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !address.isEmpty, !username.isEmpty, hasUsableSecret,
              let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port) else { return nil }
        let base = Draft(
            name: name, endpoint: SSHEndpoint(host: address, port: port, username: username),
            herdr: HerdrInstallation(path: herdrPath, session: herdrSession), connectionMethod: connectionMethod,
            authentication: selectedAuthentication, secret: enteredSecret)
        return Draft(base, pin: pin(for: base))
    }

    /// HTTPS 主機：名稱、https 位址，以及配對碼(已存的 HTTPS 主機可以不填，沿用存著的權杖)。
    private var hostServiceDraft: Draft? {
        let name = name.trimmingCharacters(in: .whitespaces)
        let code = pairingCode.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let address = HostServiceAddress(address) else { return nil }
        guard !code.isEmpty || !needsPairingCode else { return nil }
        let host = HostConfiguration(name: name, hostService: address)
        var draft = Draft(
            name: name, endpoint: host.endpoint, herdr: HerdrInstallation(), connectionMethod: .https, authentication: nil, secret: nil)
        draft.hostService = address
        draft.pairingCode = code.isEmpty ? nil : code
        return draft
    }

    /// 只有主機或埠改變(或新主機)才重設 pin;改名稱、使用者、herdr 設定不重設(行為規格 §8.2)。
    private func pin(for draft: Draft) -> HostKeyFingerprint? {
        if let accepted, Self.sameMachine(accepted.endpoint, draft.endpoint) { return accepted.fingerprint }
        if let existing, Self.sameMachine(existing.endpoint, draft.endpoint) { return existing.hostKeyPin }
        return nil
    }

    private static func sameMachine(_ lhs: SSHEndpoint, _ rhs: SSHEndpoint) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }
}

extension HostEditorModel.KeyCheck {
    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}
