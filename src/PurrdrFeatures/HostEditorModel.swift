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
        /// 用密碼加入公鑰前，說明會寫什麼並等使用者同意(ADR-0002)。
        case confirmKeyInstall
        case installingKey
        /// 用密碼加入公鑰失敗;手動指令仍可用。
        case keyInstallFailed(String)
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

    /// 連線方式之下出現的欄位(#250),依畫面順序。
    public enum ConnectionField: Sendable, Equatable {
        case address
        case port
        case username
        /// OpenSSH 的登入方式(這台裝置的金鑰／匯入私鑰／密碼)。
        case signIn
        case pairingCode
        /// herdr 路徑與 Session。
        case advanced
    }

    public var name = ""
    /// SSH 是主機名稱或 IP;HTTPS 是主機服務的主機名稱(埠在 `port`)。
    public var address = ""
    /// 使用者改過就不再跟著連線方式換預設值。
    public var port: String {
        get { portText }
        set {
            portText = newValue
            isPortEdited = true
        }
    }
    public var username = ""
    /// 空白為 `herdr`。
    public var herdrPath = ""
    /// 空白為預設 session。
    public var herdrSession = ""
    /// 新主機還沒選是 `nil`,這時不出現連線欄位。換方式時，沒手動改過的 Port 換成新方式的預設。
    public var connectionMethod: HostConfiguration.ConnectionMethod? {
        get { chosenMethod }
        set {
            chosenMethod = newValue
            if let newValue, !isPortEdited { portText = String(newValue.defaultPort) }
        }
    }
    /// OpenSSH 的登入方式。預設用這支裝置的金鑰。
    public var authentication: HostConfiguration.OpenSSHAuthentication = .deviceKey
    /// 編輯既有主機時留空 = 保留原本的密碼。
    public var password = ""
    /// 貼上的 OpenSSH 私鑰。編輯既有主機時留空 = 保留原本的金鑰。
    public var privateKeyText = ""
    /// HTTPS 主機的配對碼(主機配對指令顯示的)。編輯已配對的主機時留空 = 沿用存著的裝置權杖。
    public var pairingCode = ""
    /// 用密碼加入這支裝置的公鑰時輸入的密碼(#285):只用來登入一次，不存。
    public var keyInstallPassword = ""
    /// 主機圖示(#239)。只改圖示時不必重新測試連線就能儲存。
    public var icon: HostIcon
    public private(set) var phase: Phase = .editing
    /// 最近一次用密碼加入公鑰的結果。
    public private(set) var keyInstallOutcome: AuthorizedKeyInstallOutcome?
    /// 這支裝置的公鑰(含註解),`loadDeviceKey()` 之後才有。
    public private(set) var devicePublicKey: SSHPublicKey?
    /// 拿不到裝置金鑰時的說明。
    public private(set) var deviceKeyProblem: String?

    /// 是否是編輯既有主機。
    public var isEditing: Bool { existing != nil }

    /// herdr 過舊時能不能由 Purrdr 更新(SSH 才能;HTTPS 請使用者在主機上更新)。
    public var canUpdateHerdr: Bool { connectionMethod?.usesHostService != true }

    /// HTTPS 主機要輸入配對碼：新主機，或這支裝置還沒有它的裝置權杖(例如主機同步帶來的)。
    public var needsPairingCode: Bool { connectionMethod?.usesHostService == true && !hasStoredDeviceToken }

    /// 目前連線方式要填的欄位;還沒選連線方式時沒有。
    public var connectionFields: [ConnectionField] {
        switch connectionMethod {
        case nil: []
        case .tailscaleSSH?: [.address, .port, .username, .advanced]
        case .openSSH?: [.address, .port, .username, .signIn, .advanced]
        case .https?: [.address, .port, .pairingCode]
        }
    }

    /// 可以輸入文字的欄位(#312):鍵盤焦點與 return 的去向。
    public enum InputField: Hashable, Sendable {
        case name
        case address
        case port
        case username
        case pairingCode
        /// 密碼登入的密碼。
        case password
        /// 匯入的私鑰(多行，return 是換行)。
        case privateKey
        /// 用密碼加入這支裝置公鑰的密碼(#285)。
        case keyInstallPassword
        case herdrPath
        case herdrSession
    }

    /// 目前顯示中的輸入欄位，依畫面順序;隱藏的欄位不在內。
    /// - Parameter showsAdvanced: 「進階」是否展開(展開狀態屬於畫面)。
    public func inputFields(showsAdvanced: Bool) -> [InputField] {
        var fields: [InputField] = [.name]
        for field in connectionFields {
            switch field {
            case .address: fields.append(.address)
            case .port: fields.append(.port)
            case .username: fields.append(.username)
            case .pairingCode: fields.append(.pairingCode)
            case .signIn:
                switch authentication {
                case .password: fields.append(.password)
                case .importedKey:
                    if !keyCheck.isValid { fields.append(.privateKey) }
                case .deviceKey:
                    if devicePublicKey != nil { fields.append(.keyInstallPassword) }
                }
            case .advanced:
                if showsAdvanced { fields += [.herdrPath, .herdrSession] }
            }
        }
        return fields
    }

    /// 單行欄位按 return 要移到的欄位;最後一個(或不在顯示中)是 `nil`,收起鍵盤。
    /// 不在 return 時執行寫入主機的動作(ADR-0002 的同意流程仍要按按鈕)。
    public func inputField(after field: InputField, showsAdvanced: Bool) -> InputField? {
        let fields = inputFields(showsAdvanced: showsAdvanced)
        guard let index = fields.firstIndex(of: field), index + 1 < fields.count else { return nil }
        return fields[index + 1]
    }

    private var chosenMethod: HostConfiguration.ConnectionMethod?
    private var portText = ""
    private var isPortEdited = false
    private let store: any HostStore
    private let existing: HostConfiguration?
    private let originalIcon: HostIcon
    /// 儲存後套用圖示(主機 id 存好才知道)。
    private let saveIcon: @MainActor (HostIcon, UUID) -> Void
    private let credentials: HostCredentials
    private let consent: any HostWriteConsentStore
    /// 新主機在編輯時就決定 id:同意(以主機 id 記)要對得上儲存後的主機。
    private let hostID: UUID
    /// 確認 host key 後要繼續的是加入公鑰，不是連線測試。
    private var resumesKeyInstall = false
    private let hostService: HostServiceAccess
    /// 編輯的 HTTPS 主機在這支裝置已有裝置權杖。
    private let hasStoredDeviceToken: Bool
    /// 這次編輯中配對拿到的權杖(配對碼只能用一次，再測沿用)。
    private var pairing: Pairing?
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    /// 最近一次檢查的私鑰輸入與結果。
    private var checked: (input: HostSecret, result: KeyCheck)?
    /// 這次編輯中使用者確認過的指紋，以及它屬於哪個端點。
    private var accepted: (fingerprint: HostKeyFingerprint, endpoint: SSHEndpoint)?
    private var tested: (draft: Draft, operatingSystem: HostOperatingSystem?)?
    private var attempt = 0

    public init(
        store: any HostStore, editing: HostConfiguration? = nil, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(), consent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        icon: HostIcon = .default, saveIcon: @escaping @MainActor (HostIcon, UUID) -> Void = { _, _ in },
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.store = store
        existing = editing
        hostID = editing?.id ?? UUID()
        self.consent = consent
        self.icon = icon
        originalIcon = icon
        self.saveIcon = saveIcon
        self.credentials = credentials
        self.hostService = hostService
        self.makeChannel = makeChannel
        hasStoredDeviceToken = editing.map {
            $0.connectionMethod.usesHostService && (try? hostService.tokens.deviceToken(for: $0.id)) != nil
        } ?? false
        guard let editing else { return }
        name = editing.name
        chosenMethod = editing.connectionMethod
        if let settings = editing.ssh {
            address = settings.endpoint.host
            loadPort(settings.endpoint.port)
            username = settings.endpoint.username
            herdrPath = settings.herdr.path == "herdr" ? "" : settings.herdr.path
            herdrSession = settings.herdr.session ?? ""
            authentication = editing.authentication ?? .deviceKey
        } else if let hostServiceAddress = editing.hostService {
            loadHostService(hostServiceAddress)
        }
    }

    /// 從主機分享連結匯入：新主機，欄位帶入分享內容。分享內容附的 host key 指紋視為已確認，
    /// 所以連線測試只接受那一把 key(主機出示別的 key 時一樣阻擋);仍要測試通過才能儲存。
    public convenience init(
        store: any HostStore, importing shared: SharedHost, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(), consent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        saveIcon: @escaping @MainActor (HostIcon, UUID) -> Void = { _, _ in },
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.init(
            store: store, editing: nil, credentials: credentials, hostService: hostService, consent: consent, saveIcon: saveIcon,
            makeChannel: makeChannel)
        name = shared.name
        chosenMethod = shared.connectionMethod
        if let hostService = shared.hostService {
            loadHostService(hostService)
        } else {
            address = shared.endpoint.host
            loadPort(shared.endpoint.port)
        }
        username = shared.endpoint.username
        herdrPath = shared.herdr.path == "herdr" ? "" : shared.herdr.path
        herdrSession = shared.herdr.session ?? ""
        if let pin = shared.hostKeyPin { accepted = (pin, shared.endpoint) }
    }

    /// 從主機配對指令的 QR code(`purrdr://pair?…`)新增 HTTPS 主機：帶入位址與配對碼，名稱預設是主機名稱的第一段。
    public convenience init(
        store: any HostStore, pairing link: HostServicePairingLink, credentials: HostCredentials = HostCredentials(),
        hostService: HostServiceAccess = HostServiceAccess(), consent: any HostWriteConsentStore = InMemoryHostWriteConsentStore(),
        saveIcon: @escaping @MainActor (HostIcon, UUID) -> Void = { _, _ in },
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.init(
            store: store, editing: nil, credentials: credentials, hostService: hostService, consent: consent, saveIcon: saveIcon,
            makeChannel: makeChannel)
        apply(link)
    }

    /// 掃到的 QR code 內容(#250):是配對連結就選 HTTPS 並填好位址、Port、配對碼(名稱空白時用主機名稱第一段);不是就不動。
    @discardableResult
    public func applyScannedCode(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = try? HostServicePairingLink(url: url) else { return false }
        apply(link)
        return true
    }

    private func apply(_ link: HostServicePairingLink) {
        chosenMethod = .https
        loadHostService(link.address)
        pairingCode = link.pairingCode
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = link.address.hostName.split(separator: ".").first.map(String.init) ?? link.address.hostName
        }
    }

    /// HTTPS 位址拆成位址欄位與 Port 欄位(舊資料 `https://x:8443` 也一樣)。
    private func loadHostService(_ hostService: HostServiceAddress) {
        address = hostService.hostName
        loadPort(hostService.port)
    }

    /// 帶入已有的 Port;與連線方式的預設不同時視為使用者指定，換方式不覆蓋。
    private func loadPort(_ value: Int) {
        portText = String(value)
        isPortEdited = value != chosenMethod?.defaultPort
    }

    // MARK: - 狀態

    public var canTest: Bool { draft != nil && phase != .testing && phase != .updating && phase != .installingKey }

    /// 最近一次測試成功，而且之後沒有改過任何欄位。
    public var canSave: Bool {
        if changesOnlyIcon { return true }
        guard let tested else { return false }
        switch phase {
        case .tested, .connected: return tested.draft == draft
        default: return false
        }
    }

    /// 有沒有未儲存的變更(按取消時要確認放棄)。
    public var hasChanges: Bool { settingsChanged || icon != originalIcon }

    /// 編輯既有主機時只改了圖示：不必測試連線，儲存也不動主機設定與連線。
    public var changesOnlyIcon: Bool { existing != nil && icon != originalIcon && !settingsChanged }

    private var settingsChanged: Bool {
        let secretsEntered = !(password.isEmpty && privateKeyText.isEmpty && pairingCode.isEmpty)
        guard let existing else {
            return secretsEntered || !(name.isEmpty && address.isEmpty && username.isEmpty && herdrPath.isEmpty && herdrSession.isEmpty)
        }
        guard let draft else { return true }
        return secretsEntered || draft.name != existing.name || !draft.connection.sameSettings(as: existing.connection)
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
    public var hostKeyFingerprint: HostKeyFingerprint? {
        guard case .ssh(let ssh) = draft?.connection else { return nil }
        return ssh.settings.hostKeyPin
    }

    // MARK: - 動作

    /// 連線測試：主機 OS、herdr 版本、snapshot、agent 整合。
    public func test() async {
        guard let draft else { return }
        guard case .ssh(let ssh) = draft.connection else { return await testHostService(draft) }
        resumesKeyInstall = false
        attempt += 1
        let current = attempt
        phase = .testing
        let channel = makeChannel(ssh.settings.endpoint, ssh.settings.hostKeyPin, credential(for: ssh))
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
    private func testHostService(_ draft: Draft) async {
        guard case .https(let address, let pairingCode) = draft.connection else { return }
        attempt += 1
        let current = attempt
        phase = .testing
        let result: Result<HostServiceCheck, any Error>
        do {
            let testToken = try await deviceToken(address: address, pairingCode: pairingCode)
            let connection = hostService.makeConnection(address) { testToken.deviceToken }
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
        let device = try await hostService.pairing.pair(address: address, pairingCode: code, deviceName: hostService.deviceName)
        discardUnsavedPairing()
        pairing = Pairing(address: address, code: code, device: device)
        return TestToken(deviceToken: device.deviceToken, readOnly: device.readOnly)
    }

    /// 配對拿到的權杖沒存下來(取消、離開編輯器):請主機撤銷，主機不留沒用的權杖。
    public func discardUnsavedPairing() {
        guard let pairing, !pairing.isSaved else { return }
        self.pairing = nil
        hostService.revokeWithoutWaiting(pairing.device.deviceToken, at: pairing.address)
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

    // MARK: - 用密碼加入公鑰(#285)

    /// OpenSSH 選這支裝置的金鑰、公鑰已取得、連線欄位與密碼都填好時可以加入。
    public var canInstallDeviceKey: Bool {
        guard selectedAuthentication == .deviceKey, devicePublicKey != nil, !keyInstallPassword.isEmpty,
              case .ssh = draft?.connection else { return false }
        return phase != .testing && phase != .updating && phase != .installingKey
    }

    /// 先說明會寫什麼、等使用者同意;同意前不連主機。
    public func requestKeyInstall() {
        guard canInstallDeviceKey else { return }
        phase = .confirmKeyInstall
    }

    /// 使用者同意：記下同意，用密碼登入一次把公鑰寫進主機，成功後改用金鑰測試連線。
    public func confirmKeyInstall() async {
        guard phase == .confirmKeyInstall else { return }
        consent.grant(AuthorizedKeyInstaller.feature.id, host: hostID.uuidString)
        await installDeviceKey()
    }

    private func installDeviceKey() async {
        guard case .ssh(let ssh) = draft?.connection, let publicKey = devicePublicKey else { return }
        resumesKeyInstall = false
        attempt += 1
        let current = attempt
        phase = .installingKey
        let password = keyInstallPassword
        let base = makeChannel(ssh.settings.endpoint, ssh.settings.hostKeyPin) { .password(password) }
        let result: Result<AuthorizedKeyInstallOutcome, any Error>
        do {
            let channel = OperatingSystemDetectingChannel(base) { _ in }
            result = .success(try await AuthorizedKeyInstaller(channel: channel).install(publicKey))
        } catch {
            result = .failure(error)
        }
        await base.disconnect()
        guard current == attempt else { return }
        switch result {
        case .success(let outcome):
            keyInstallOutcome = outcome
            keyInstallPassword = ""
            await test()
        case .failure(SSHConnectionError.hostKeyUnverified(let presented)):
            resumesKeyInstall = true
            phase = .confirmHostKey(presented)
        case .failure(SSHConnectionError.hostKeyChanged(let presented, let pinned)):
            resumesKeyInstall = true
            phase = .hostKeyChanged(presented: presented, pinned: pinned)
        case .failure(let error):
            phase = .keyInstallFailed(Self.keyInstallMessage(for: error))
        }
    }

    private static func keyInstallMessage(for error: any Error) -> String {
        switch error {
        case AuthorizedKeyInstallError.failed(let reason):
            return String(localized: "Couldn’t add the key on the host. \(reason)")
        case HostFilesError.failed(_, let reason) where !reason.isEmpty:
            return String(localized: "Couldn’t add the key on the host. \(reason)")
        default:
            break
        }
        return HostErrorText.message(for: error, connection: .openSSH, authentication: .password)
    }

    /// 取消進行中的測試。
    public func cancelTest() {
        attempt += 1
        phase = .editing
    }

    /// 信任主機剛剛出示的那一把 key,再重新測試。永遠不清空 pin 然後信任下一個回應者(行為規格 §8.2)。
    public func trustPresentedHostKey() async {
        guard case .ssh(let ssh) = draft?.connection else { return }
        let presented: HostKeyFingerprint
        switch phase {
        case .confirmHostKey(let fingerprint), .hostKeyChanged(let fingerprint, _): presented = fingerprint
        default: return
        }
        accepted = (presented, ssh.settings.endpoint)
        if resumesKeyInstall {
            await installDeviceKey()
        } else {
            await test()
        }
    }

    /// 不信任、不更新、不加入公鑰：回到編輯。
    public func dismissPrompt() {
        resumesKeyInstall = false
        phase = .editing
    }

    /// 使用者確認後在主機上更新 herdr(macOS／Linux 是 `herdr update --handoff`),再重新測試。
    /// Windows 的伺服器不會交接到新版：先請使用者在主機上重啟伺服器，不馬上重測(重測只會再看到舊版)。
    public func updateHerdr() async {
        guard case .ssh(let ssh) = draft?.connection, case .needsUpdate = phase else { return }
        phase = .updating
        let channel = makeChannel(ssh.settings.endpoint, ssh.settings.hostKeyPin, credential(for: ssh))
        let outcome: HerdrUpdateOutcome
        do {
            outcome = try await HostProbe(channel: channel, herdr: ssh.settings.herdr).updateHerdr()
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            phase = .failed(HostErrorText.message(for: error, connection: ssh.method, authentication: ssh.authentication))
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
        if changesOnlyIcon, let existing {
            saveIcon(icon, existing.id)
            return existing
        }
        guard let host = saveSettings() else { return nil }
        if icon != originalIcon { saveIcon(icon, host.id) }
        return host
    }

    private func saveSettings() -> HostConfiguration? {
        guard canSave, let tested else { return nil }
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
    private func saveHostService(_ host: HostConfiguration, pairingCode: String?) -> HostConfiguration? {
        let newToken = pairingCode == nil ? nil : pairing?.device.deviceToken
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
        if newToken != nil { pairing?.isSaved = true }
        // 重新配對換了權杖：舊的請主機撤銷。
        if let newToken, let previousToken, previousToken != newToken, let previousAddress = existing?.hostService {
            hostService.revokeWithoutWaiting(previousToken, at: previousAddress)
        }
        return host
    }

    // MARK: - 內部

    /// 這次編輯中以配對碼換得的權杖。
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

    private struct Draft: Equatable {
        enum Connection: Equatable {
            case ssh(SSHDraft)
            /// 配對碼 `nil` = 沿用存著的權杖。
            case https(HostServiceAddress, pairingCode: String?)

            /// 與已存主機的設定相同(不看 host key pin 與祕密)。
            func sameSettings(as saved: HostConfiguration.Connection) -> Bool {
                switch self {
                case .ssh(let ssh):
                    ssh.settings.endpoint == saved.ssh?.endpoint && ssh.settings.herdr == saved.ssh?.herdr
                        && ssh.authentication == saved.authentication
                case .https(let address, _):
                    address == saved.hostService
                }
            }
        }

        var name: String
        var connection: Connection
    }

    /// SSH 主機的草稿：pin 是這次編輯中信任的指紋。
    private struct SSHDraft: Equatable {
        var settings: HostConfiguration.SSHSettings
        /// OpenSSH 的登入方式;Tailscale SSH 為 `nil`。
        var authentication: HostConfiguration.OpenSSHAuthentication?
        /// 這次輸入的祕密;`nil` = 不需要或沿用已存的。
        var secret: HostSecret?

        var method: HostConfiguration.ConnectionMethod { authentication == nil ? .tailscaleSSH : .openSSH }

        var connection: HostConfiguration.Connection {
            authentication.map { .openSSH(settings, authentication: $0) } ?? .tailscaleSSH(settings)
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

    private func credential(for ssh: SSHDraft) -> SSHCredentialProvider {
        credentials.provider(
            method: ssh.method, authentication: ssh.authentication, hostID: ssh.secret == nil ? existing?.id : nil, entered: ssh.secret)
    }

    private var draft: Draft? {
        guard let connectionMethod else { return nil }
        if connectionMethod.usesHostService { return hostServiceDraft }
        let name = name.trimmingCharacters(in: .whitespaces)
        let address = address.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !address.isEmpty, !username.isEmpty, hasUsableSecret,
              let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port) else { return nil }
        let endpoint = SSHEndpoint(host: address, port: port, username: username)
        let settings = HostConfiguration.SSHSettings(
            endpoint: endpoint, herdr: HerdrInstallation(path: herdrPath, session: herdrSession), hostKeyPin: pin(for: endpoint))
        return Draft(name: name, connection: .ssh(SSHDraft(settings: settings, authentication: selectedAuthentication, secret: enteredSecret)))
    }

    /// HTTPS 主機：名稱、https 位址，以及配對碼(已存的 HTTPS 主機可以不填，沿用存著的權杖)。
    private var hostServiceDraft: Draft? {
        let name = name.trimmingCharacters(in: .whitespaces)
        // 配對碼是大寫字母：硬體鍵盤與貼上打的小寫也算(#236)。
        let code = pairingCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty, let address = HostServiceAddress(addressField: address, portField: port) else { return nil }
        guard !code.isEmpty || !needsPairingCode else { return nil }
        return Draft(name: name, connection: .https(address, pairingCode: code.isEmpty ? nil : code))
    }

    /// 只有主機或埠改變(或新主機)才重設 pin;改名稱、使用者、herdr 設定不重設(行為規格 §8.2)。
    private func pin(for endpoint: SSHEndpoint) -> HostKeyFingerprint? {
        if let accepted, Self.sameMachine(accepted.endpoint, endpoint) { return accepted.fingerprint }
        if let saved = existing?.ssh, Self.sameMachine(saved.endpoint, endpoint) { return saved.hostKeyPin }
        return nil
    }

    private static func sameMachine(_ lhs: SSHEndpoint, _ rhs: SSHEndpoint) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }
}

private extension HostConfiguration.ConnectionMethod {
    /// 加入主機頁的 Port 預設(#250)。
    var defaultPort: Int { usesHostService ? 443 : 22 }
}

extension HostEditorModel.KeyCheck {
    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}
