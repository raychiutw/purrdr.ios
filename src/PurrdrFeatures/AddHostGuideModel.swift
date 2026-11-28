import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 引導裡「在電腦上做一件事」的一步:一句話，可帶可拷貝的指令或連結。文字已依 app 語言翻譯。
public struct AddHostGuideInstruction: Equatable, Sendable {
    public var text: String
    /// 可拷貝與分享到電腦的指令。
    public var command: String?
    /// 可開啟與分享到電腦的網頁(例：Tailscale 下載頁)。
    public var link: URL?
    /// 連結按鈕上的字。
    public var linkTitle: String?

    public init(text: String, command: String? = nil, link: URL? = nil, linkTitle: String? = nil) {
        self.text = text
        self.command = command
        self.link = link
        self.linkTitle = linkTitle
    }
}

/// 新增主機引導(#341,spec #332):一頁只問一件事的狀態機。
///
/// 只負責「問什麼、順序、文字」:連線測試、主機身分確認、儲存都交給共用的 `HostConnectionFlow`(#340)。
/// 步驟資料集中在這裡(依作業系統與連線方式組出步驟與指令),畫面只呈現;後續票(原生 SSH、HTTPS、失敗提醒)加步驟與答案即可。
/// 有 Tailscale SSH、原生 SSH 與 HTTPS 路徑,以及匯入與待配對的捷徑。
@MainActor
@Observable
public final class AddHostGuideModel {
    public enum Step: Hashable, Sendable {
        case kind
        /// HTTPS:先準備 Tailscale(iPhone 與電腦)。
        case tailscale
        case system
        /// HTTPS:在電腦上裝主機服務。
        case install
        /// HTTPS:配對(掃 QR code 或手動輸入)。
        case pair
        case sshMethod
        /// 讓電腦接受連線。
        case enable
        /// 原生 SSH:在哪裡連(家裡、Tailscale、對外)。
        case location
        /// 主機名稱、Port、帳號。
        case details
        /// 原生 SSH:密碼或金鑰。
        case login
        /// 密碼,或匯入的私鑰。
        case credential
        /// 金鑰三步:打開終端機、貼上指令、測試連線。
        case keySetup
        /// 測試連線(含第一次連線的信任確認)。
        case test
        case finished
    }

    /// 最後一頁的通知選項(#675):登入了給這台主機的開關,沒登入就一行登入提示。
    public enum NotificationOffer: Equatable, Sendable {
        case toggle
        case signIn
    }

    public enum Kind: Hashable, Sendable {
        case ssh
        case https
    }

    public enum SSHMethod: Hashable, Sendable {
        case tailscale
        /// 原生 SSH(Windows 是 OpenSSH)。
        case native
    }

    /// 原生 SSH 從哪裡連到電腦。
    public enum Location: Hashable, Sendable {
        /// 只在家裡(同一個 Wi-Fi)。
        case home
        /// 透過 Tailscale(MagicDNS 名稱或 Tailscale IP)。
        case viaTailscale
        /// 對外 IP 或網域。
        case outside
    }

    /// 要填的欄位(附「怎麼查」)。
    public enum Field: Hashable, Sendable {
        case address
        case port
        case username
        /// HTTPS 配對:主機服務位址、Port、配對碼。
        case pairAddress
        case pairPort
        case pairingCode
        /// 原生 SSH 的密碼、匯入的私鑰(多行)。
        case password
        case privateKey

        /// return 鍵移到的下一欄;最後一欄或沒有 return 的欄位是 `nil`(收鍵盤，#312)。
        public var next: Field? {
            switch self {
            case .address: .port
            case .port: .username
            case .pairAddress: .pairPort
            case .pairPort: .pairingCode
            case .username, .pairingCode, .password, .privateKey: nil
            }
        }
    }

    /// 從別處帶著資料進來的捷徑(#344):跳過前面的步驟。
    public enum Shortcut: Sendable {
        /// 主機分享連結或配對 QR code 的連結。
        case importLink(URL)
        /// 同步來、這支裝置還沒配對的 HTTPS 主機。
        case needsPairing(HostConfiguration)
    }

    public enum ShortcutError: Error, Equatable, Sendable {
        /// 引導接不了(例如缺主機服務位址的 HTTPS 主機)。
        case needsEditor
    }

    public private(set) var step: Step = .kind
    /// 預設推薦 SSH。
    public var kind: Kind = .ssh
    public private(set) var system: HostOperatingSystem?
    public private(set) var sshMethod: SSHMethod?
    public private(set) var location: Location?
    public private(set) var authentication: HostConfiguration.OpenSSHAuthentication?
    /// 密碼路徑填的密碼。
    public var password = ""
    /// 匯入私鑰路徑貼上的私鑰。
    public var privateKey = ""
    /// 這支裝置的公鑰(金鑰路徑;`loadDeviceKey()` 取得)。
    public private(set) var devicePublicKey: SSHPublicKey?
    /// 拿不到裝置金鑰時的說明。
    public private(set) var deviceKeyProblem: DisplayedError?
    public var address = ""
    public var port = "22"
    /// HTTPS:主機服務的位址(主機名稱)、Port 與配對碼。
    public var pairAddress = ""
    public var pairPort = "443"
    /// 主機服務位址的規則(#696):Release 只收 https。預設跟著 app 入口設的 `HostServiceAddress.Policy.current`。
    public var addressPolicy: HostServiceAddress.Policy = .current
    /// 手動輸入的位址是 http 或本機位址、被規則擋下:畫面提示「位址要是 https」。
    public var pairAddressNeedsHTTPS: Bool {
        HostServiceAddress.isRejected(pairAddress.trimmingCharacters(in: .whitespaces), by: addressPolicy)
    }
    public var pairingCode = ""
    public var username = ""
    /// 儲存完成的主機。
    public private(set) var savedHost: HostConfiguration?
    /// 最後一頁的通知選項(`loadNotificationOffer()` 之後才有)。
    public private(set) var notificationOffer: NotificationOffer?
    public var phase: HostConnectionPhase { flow.phase }
    /// 從外部連結直接到測試頁:先顯示位址，使用者按下才測試(`testConnection()` 之後為 `false`)。
    public private(set) var awaitsTestConfirmation = false
    /// 測試頁顯示的完整連線目標(`主機:Port`，SSH 前面加帳號)。
    public var connectionTarget: String {
        if kind == .https { return "\(pairAddress):\(pairPort)" }
        return "\(username)@\(address):\(port)"
    }

    @ObservationIgnored private let flow: HostConnectionFlow
    @ObservationIgnored private let credentials: HostCredentials
    @ObservationIgnored private let isSignedIn: @MainActor () async -> Bool
    /// 匯入或待配對時沿用的主機名稱。
    @ObservationIgnored private var presetName: String?
    /// 匯入的原生 SSH 連結:選完電腦種類直接到登入方式。
    @ObservationIgnored private var continuesAtLogin = false
    @ObservationIgnored private var history: [Step] = []
    /// 儲存時 `history` 會清空,完成頁之前疊著的頁留在這裡給 `pages`。
    @ObservationIgnored private var archivedPages: [Step] = []

    public init(
        store: any HostStore, credentials: HostCredentials = HostCredentials(), hostService: HostServiceAccess = HostServiceAccess(),
        existing: HostConfiguration? = nil, isSignedIn: @escaping @MainActor () async -> Bool = { false },
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        self.credentials = credentials
        self.isSignedIn = isSignedIn
        flow = HostConnectionFlow(
            store: store, existing: existing, credentials: credentials, hostService: hostService, makeChannel: makeChannel)
    }

    /// 帶著資料進來:匯入(資料已齊直接到測試連線;HTTPS 分享連結沒有配對碼，到配對)或待配對(直接到配對)。
    public convenience init(
        store: any HostStore, credentials: HostCredentials = HostCredentials(), hostService: HostServiceAccess = HostServiceAccess(),
        isSignedIn: @escaping @MainActor () async -> Bool = { false },
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel,
        shortcut: Shortcut, addressPolicy: HostServiceAddress.Policy = .current
    ) throws {
        switch shortcut {
        case .needsPairing(let host):
            guard let address = host.hostService else { throw ShortcutError.needsEditor }
            self.init(
                store: store, credentials: credentials, hostService: hostService, existing: host, isSignedIn: isSignedIn,
                makeChannel: makeChannel)
            kind = .https
            presetName = host.name
            load(address)
            step = .pair
        case .importLink(let url):
            if HostServicePairingLink.isPairingLink(url) {
                let link = try HostServicePairingLink(url: url, policy: addressPolicy)
                self.init(store: store, credentials: credentials, hostService: hostService, isSignedIn: isSignedIn, makeChannel: makeChannel)
                self.addressPolicy = addressPolicy
                kind = .https
                load(link.address)
                pairingCode = link.pairingCode
                step = .test
                awaitsTestConfirmation = true
                return
            }
            let shared = try HostShareLink.decode(url, policy: addressPolicy)
            self.init(store: store, credentials: credentials, hostService: hostService, isSignedIn: isSignedIn, makeChannel: makeChannel)
            self.addressPolicy = addressPolicy
            presetName = shared.name
            switch shared.connectionMethod {
            case .https:
                guard let address = shared.hostService else { throw ShortcutError.needsEditor }
                kind = .https
                load(address)
                step = .pair
            case .tailscaleSSH:
                kind = .ssh
                sshMethod = .tailscale
                address = shared.endpoint.host
                port = String(shared.endpoint.port)
                username = shared.endpoint.username
                flow.acceptSharedPin(of: shared)
                step = .test
                awaitsTestConfirmation = true
            case .openSSH:
                // 位址、Port、帳號與 host key 已帶入:只問電腦種類(金鑰指令要依它),再選登入方式,不問連線方式與位址。
                kind = .ssh
                sshMethod = .native
                address = shared.endpoint.host
                port = String(shared.endpoint.port)
                username = shared.endpoint.username
                flow.acceptSharedPin(of: shared)
                continuesAtLogin = true
                step = .system
            }
        }
    }

    /// 失敗說明的「詳細資訊」(原始錯誤內容;沒有時 `nil`,#359)。
    public var failureDetails: String? { flow.failureDetails }

    /// 接上數據用量計量(#353):連線測試與配對的流量記在這台新主機底下。
    package func attachTraffic(_ provider: @escaping (UUID) -> TrafficRecording) {
        flow.traffic = provider
    }

    private func load(_ address: HostServiceAddress) {
        pairAddress = address.hostName
        pairPort = String(address.port)
    }

    // MARK: - 進度

    public var canGoBack: Bool { !history.isEmpty && step != .finished }

    /// 畫面上疊著的頁(#622:每一步是一頁 push,系統返回鈕對應 `back()`):從第一頁到目前這一步。
    /// 儲存後到完成頁時,前面的頁照舊留著(完成頁沒有上一步,返回鈕隱藏)。
    public var pages: [Step] {
        step == .finished ? archivedPages + [.finished] : history + [step]
    }

    /// 目前第幾步、共幾步(VoiceOver 與進度點)。
    public var progress: (position: Int, total: Int) {
        let path: [Step]
        switch (kind, sshMethod) {
        case (.https, _): path = Self.httpsPath
        case (_, .native?): path = Self.nativePath
        default: path = Self.sshPath
        }
        let current: Step = step == .keySetup ? .credential : step
        return ((path.firstIndex(of: current) ?? path.count - 1) + 1, path.count)
    }

    private static let sshPath: [Step] = [.kind, .system, .sshMethod, .enable, .details, .test]
    private static let nativePath: [Step] = [.kind, .system, .sshMethod, .enable, .location, .details, .login, .credential, .test]
    private static let httpsPath: [Step] = [.kind, .tailscale, .system, .install, .pair, .test]

    /// 目前這一頁的「下一步」按鈕能不能按(開啟 SSH 那頁一律可以)。
    public var canAdvance: Bool {
        switch step {
        case .enable, .tailscale, .install: true
        case .location: false
        case .details: sshDraft != nil
        case .pair: httpsDraft != nil
        case .credential:
            switch authentication {
            case .password?: !password.isEmpty
            case .importedKey?: (try? SSHPrivateKey(openSSH: privateKey)) != nil
            default: false
            }
        case .keySetup: devicePublicKey != nil
        default: false
        }
    }

    // MARK: - 選擇

    public func choose(_ kind: Kind) {
        self.kind = kind
        switch kind {
        case .ssh: push(.system)
        case .https: push(.tailscale)
        }
    }

    public func choose(_ system: HostOperatingSystem) {
        self.system = system
        push(kind == .https ? .install : (continuesAtLogin ? .login : .sshMethod))
    }

    public func choose(_ method: SSHMethod) {
        sshMethod = method
        switch method {
        case .tailscale: push(.enable)
        case .native: push(.enable)
        }
    }

    public func choose(_ location: Location) {
        self.location = location
        push(.details)
    }

    /// 選登入方式:密碼、這支裝置的金鑰,或匯入現有私鑰(其他方式)。
    public func choose(authentication: HostConfiguration.OpenSSHAuthentication) {
        self.authentication = authentication
        push(authentication == .deviceKey ? .keySetup : .credential)
    }

    /// 選了作業系統之後可選的 SSH 方式:Windows 沒有 Tailscale SSH,只有 OpenSSH。
    public var availableSSHMethods: [SSHMethod] {
        system == .windows ? [.native] : [.tailscale, .native]
    }

    // MARK: - 步驟內容

    /// 「讓電腦接受連線」的步驟。
    public var enableInstructions: [AddHostGuideInstruction] {
        switch sshMethod {
        case .tailscale?:
            [
                AddHostGuideInstruction(
                    text: String(localized: "Install Tailscale on that computer and sign in."),
                    link: Self.tailscaleDownload, linkTitle: String(localized: "Download Page")),
                AddHostGuideInstruction(
                    text: String(localized: "Open Terminal, paste this line, then press Enter."), command: "tailscale set --ssh"),
            ]
        case .native?:
            switch system {
            case .macOS?:
                [AddHostGuideInstruction(
                    text: String(localized: "On that computer, open System Settings, go to General, then Sharing, and turn on Remote Login."))]
            case .linux?:
                [AddHostGuideInstruction(
                    text: String(localized: "On that computer, open Terminal, paste this line, then press Enter."),
                    command: Self.linuxEnableSSH)]
            case .windows?:
                [
                    AddHostGuideInstruction(
                        text: String(localized: "On that computer, open PowerShell as an administrator (right-click it and choose Run as administrator).")),
                    AddHostGuideInstruction(
                        text: String(localized: "Paste this line, then press Enter."), command: Self.windowsEnableSSH),
                ]
            case nil:
                []
            }
        case nil:
            []
        }
    }

    static let linuxEnableSSH =
        "if command -v apt >/dev/null; then sudo apt install -y openssh-server && sudo systemctl enable --now ssh; "
        + "else sudo dnf install -y openssh-server && sudo systemctl enable --now sshd; fi"
    static let windowsEnableSSH =
        "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"

    /// 金鑰路徑:把這支裝置的公鑰加進電腦(三步裡的第二步)。公鑰還沒取得時是空的。
    public var keyInstructions: [AddHostGuideInstruction] {
        guard let key = devicePublicKey else { return [] }
        return DeviceKeyOnboarding.commands(for: key, system: system)
    }

    /// 取得這支裝置的公鑰(第一次會在 Secure Enclave 產生金鑰)。拿不到時 `deviceKeyProblem` 說明原因。
    public func loadDeviceKey() async {
        guard devicePublicKey == nil else { return }
        switch await DeviceKeyOnboarding.load(from: credentials) {
        case .success(let key):
            devicePublicKey = key
            deviceKeyProblem = nil
        case .failure(let error):
            deviceKeyProblem = DisplayedError(error: error)
        }
    }

    /// 貼上的私鑰不能用時的說明(RSA、passphrase、不是 OpenSSH 格式…);沒貼或可用時 `nil`。
    public var privateKeyProblem: DisplayedError? {
        guard authentication == .importedKey, !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try SSHPrivateKey(openSSH: privateKey)
            return nil
        } catch {
            return DisplayedError(HostErrorText.keyImportMessage(error), error: error)
        }
    }

    /// 這個私鑰問題可以改用這支裝置的金鑰解決(RSA 或不支援的種類)。
    public var privateKeyOffersDeviceKey: Bool {
        guard authentication == .importedKey, !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            _ = try SSHPrivateKey(openSSH: privateKey)
            return false
        } catch {
            return error == .rsaNotSupported || error.isUnsupportedKeyType
        }
    }

    /// 改用這支裝置的金鑰:清掉貼上的私鑰，到金鑰三步。
    public func useDeviceKeyInstead() {
        privateKey = ""
        choose(authentication: .deviceKey)
    }

    /// 密碼頁的提示。密碼路徑不提到金鑰;匯入私鑰才說。
    public var credentialPrompt: String {
        authentication == .importedKey
            ? String(localized: "Paste the private key you already use for that computer.")
            : String(localized: "Type the password you use to sign in to that computer.")
    }

    /// 填主機頁的提醒(對外連線要先設定路由器)。
    public var detailsNotice: String? {
        guard sshMethod == .native, location == .outside else { return nil }
        return String(localized: "Set up your router first so connections from outside can reach this host.")
    }

    static let windowsLocalIP =
        "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress"

    static let tailscaleDownload = URL(string: "https://tailscale.com/download")!
    static let tailscaleAppStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    static let hostServiceReleases = "https://github.com/raychiutw/purrdr.host/releases/latest/download/"

    /// HTTPS 第一步:iPhone 與電腦都裝 Tailscale、登入同一個帳號。
    public var tailscaleInstructions: [AddHostGuideInstruction] {
        [
            AddHostGuideInstruction(
                text: String(localized: "On this iPhone, install Tailscale and sign in."),
                link: Self.tailscaleAppStore, linkTitle: String(localized: "App Store")),
            AddHostGuideInstruction(
                text: String(localized: "On that computer, install Tailscale and sign in with the same account."),
                link: Self.tailscaleDownload, linkTitle: String(localized: "Download Page")),
        ]
    }

    /// 在電腦上裝主機服務:一行安裝指令。
    public var installInstructions: [AddHostGuideInstruction] {
        let isWindows = system == .windows
        let command = isWindows
            ? "irm \(Self.hostServiceReleases)install.ps1 | iex"
            : "curl -fsSL \(Self.hostServiceReleases)install.sh | sh"
        return [AddHostGuideInstruction(text: DeviceKeyOnboarding.pasteLineText(onWindows: isWindows), command: command)]
    }

    /// 配對:讓電腦顯示 QR code。
    public var pairInstructions: [AddHostGuideInstruction] {
        [AddHostGuideInstruction(
            text: String(localized: "Paste this line too. A QR code appears on that computer."), command: "purrdr pair")]
    }

    /// 掃到的 QR code:是配對連結就帶入位址與配對碼並直接測試連線;不是就不動。
    @discardableResult
    public func applyScannedCode(_ text: String) -> Bool {
        guard step == .pair, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let link = try? HostServicePairingLink(url: url, policy: addressPolicy)
        else { return false }
        load(link.address)
        pairingCode = link.pairingCode
        push(.test)
        return true
    }

    /// 欄位旁「怎麼查」:在電腦上做的一步與可拷貝的指令。
    public func help(for field: Field) -> AddHostGuideInstruction? {
        let isWindows = system == .windows
        switch field {
        case .address:
            let command: String
            switch (sshMethod, location) {
            case (.tailscale?, _), (_, .viaTailscale?): command = "tailscale ip -4"
            case (_, .home?):
                switch system {
                case .windows?: command = Self.windowsLocalIP
                case .linux?: command = "hostname -I"
                default: command = "ipconfig getifaddr en0"
                }
            default: return nil
            }
            return AddHostGuideInstruction(
                text: isWindows
                    ? String(localized: "On that computer, open PowerShell, paste this line, press Enter, and type the numbers that appear here.")
                    : String(localized: "On that computer, open Terminal, paste this line, press Enter, and type the numbers that appear here."),
                command: command)
        case .username:
            return AddHostGuideInstruction(
                text: isWindows
                    ? String(localized: "On that computer, open PowerShell, paste this line, press Enter, and type the name that appears here.")
                    : String(localized: "On that computer, open Terminal, paste this line, press Enter, and type the name that appears here."),
                command: isWindows ? "$env:USERNAME" : "whoami")
        case .port, .pairAddress, .pairPort, .pairingCode, .password, .privateKey:
            return nil
        }
    }

    // MARK: - 前進與返回

    /// 「我已經開好了」與填完主機後的「下一步」。
    public func advance() {
        guard canAdvance else { return }
        switch step {
        case .tailscale: push(.system)
        case .install: push(.pair)
        case .pair: push(.test)
        case .enable: push(sshMethod == .native ? .location : .details)
        case .details: push(sshMethod == .native ? .login : .test)
        case .credential, .keySetup: push(.test)
        default: break
        }
    }

    public func back() {
        guard canGoBack, let previous = history.popLast() else { return }
        if step == .test { flow.cancelTest() }
        flow.phase = .editing
        step = previous
    }

    /// 取消整個引導:停掉進行中的測試。不留下沒存的主機。
    public func cancel() {
        flow.cancelTest()
        flow.discardUnsavedPairing()
    }

    private func push(_ next: Step) {
        history.append(step)
        step = next
    }

    // MARK: - 連線測試與儲存

    /// 測試連線:第一次連線會停在主機身分確認(`phase == .confirmHostKey`)。
    public func testConnection() async {
        guard let draft else { return }
        awaitsTestConfirmation = false
        if step != .test { push(.test) }
        await flow.test(draft)
    }

    /// 信任這台電腦(主機剛出示的那一把 key),接著重新測試。
    public func trustHostKey() async {
        guard let draft, flow.trustPresentedHostKey(for: draft), let trusted = self.draft else { return }
        // 信任後的草稿帶著那把 key 當 pin:要用它重測，儲存時才對得上。
        await flow.test(trusted)
    }

    /// 儲存。測試沒通過或之後改過欄位就不存。
    @discardableResult
    public func save() -> HostConfiguration? {
        guard let host = flow.save(draft) else { return nil }
        savedHost = host
        archivedPages = history + [step]
        history.removeAll()
        step = .finished
        return host
    }

    // MARK: - 失敗提醒與最後一頁

    /// 連線失敗(`phase == .failed`)時依前面的選擇給的提醒:同一個 Wi-Fi?Tailscale 兩邊開著且同帳號?對外位址與路由器?
    /// 在外面連時另加建議用 Tailscale。主機身分變了、herdr 太舊等不是連線問題,不提醒。
    public var failureReminders: [String] {
        guard case .failed = phase else { return [] }
        let tailscale = String(localized: "Make sure Tailscale is turned on, on both this iPhone and that computer, and signed in with the same account.")
        let preferTailscale = String(localized: "When you’re away from home, Tailscale is the easiest way to connect.")
        if kind == .https {
            return [tailscale, String(localized: "Make sure the Purrdr host service is installed and running on that computer.")]
        }
        switch (sshMethod, location) {
        case (.native?, .home?):
            return [String(localized: "This iPhone and that computer must be on the same Wi-Fi."), preferTailscale]
        case (.native?, .outside?):
            return [
                String(localized: "Check that the address is the one the outside world uses, and that your router lets connections reach that computer."),
                preferTailscale,
            ]
        default:
            return [tailscale]
        }
    }

    /// 最後一頁:登入了就給這台主機的開啟通知開關,沒登入就一行登入提示(不需要 Purrdr Plus)。儲存完成前不提供。
    public func loadNotificationOffer() async {
        guard step == .finished else { return }
        notificationOffer = await isSignedIn() ? .toggle : .signIn
    }

    /// 最後一頁:用 SSH 連的主機,提示可以再裝主機服務(做完再送、卡住提醒)。
    public var suggestsHostService: Bool {
        step == .finished && savedHost?.ssh != nil
    }

    // MARK: - 內部

    private var draft: HostConnectionDraft? { kind == .https ? httpsDraft : sshDraft }

    private var httpsDraft: HostConnectionDraft? {
        let code = pairingCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty,
            let address = HostServiceAddress(
                addressField: pairAddress.trimmingCharacters(in: .whitespaces), portField: pairPort, policy: addressPolicy)
        else { return nil }
        return HostConnectionDraft(
            name: presetName ?? Self.defaultName(for: address.hostName), connection: .https(address, pairingCode: code))
    }

    private var sshDraft: HostConnectionDraft? {
        let host = address.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !user.isEmpty, let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port)
        else { return nil }
        let endpoint = SSHEndpoint(host: host, port: port, username: user)
        let settings = HostConfiguration.SSHSettings(endpoint: endpoint, herdr: HerdrInstallation(), hostKeyPin: flow.pin(for: endpoint))
        var ssh = SSHConnectionDraft(settings: settings)
        if sshMethod == .native {
            ssh.authentication = authentication ?? .password
            switch authentication {
            case .password?: ssh.secret = .password(password)
            case .importedKey?: ssh.secret = .privateKey(privateKey, passphrase: nil)
            default: break
            }
        }
        return HostConnectionDraft(name: presetName ?? Self.defaultName(for: host), connection: .ssh(ssh))
    }

    /// 主機名稱的第一段(`studio.tail1234.ts.net` → `studio`);IP 位址整串當名稱。
    static func defaultName(for host: String) -> String {
        let isNumeric = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        guard !isNumeric, let first = host.split(separator: ".").first else { return host }
        return String(first)
    }
}
