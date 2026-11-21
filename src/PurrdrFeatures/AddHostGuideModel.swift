import Foundation
import Observation
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
/// 目前有 Tailscale SSH 與 HTTPS 路徑(#344),以及匯入與待配對的捷徑;選了原生 SSH 時 `handoff` 要求畫面改開主機編輯頁。
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
        /// 主機名稱、Port、帳號。
        case details
        /// 測試連線(含第一次連線的信任確認)。
        case test
        case finished
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

    /// 要填的欄位(附「怎麼查」)。
    public enum Field: Hashable, Sendable {
        case address
        case port
        case username
        /// HTTPS 配對:主機服務位址、Port、配對碼。
        case pairAddress
        case pairPort
        case pairingCode
    }

    /// 這個引導接不了、要換成別的畫面。
    public enum Handoff: Equatable, Sendable {
        /// 主機編輯頁,預選這種連線方式。
        case editor(HostConfiguration.ConnectionMethod)
    }

    /// 從別處帶著資料進來的捷徑(#344):跳過前面的步驟。
    public enum Shortcut: Sendable {
        /// 主機分享連結或配對 QR code 的連結。
        case importLink(URL)
        /// 同步來、這支裝置還沒配對的 HTTPS 主機。
        case needsPairing(HostConfiguration)
    }

    public enum ShortcutError: Error, Equatable, Sendable {
        /// 引導接不了(例如原生 SSH 的分享連結要另外填登入方式):畫面改開主機編輯頁。
        case needsEditor
    }

    public private(set) var step: Step = .kind
    /// 預設推薦 SSH。
    public var kind: Kind = .ssh
    public private(set) var system: HostOperatingSystem?
    public private(set) var sshMethod: SSHMethod?
    public var address = ""
    public var port = "22"
    /// HTTPS:主機服務的位址(主機名稱)、Port 與配對碼。
    public var pairAddress = ""
    public var pairPort = "443"
    public var pairingCode = ""
    public var username = ""
    public private(set) var handoff: Handoff?
    /// 儲存完成的主機。
    public private(set) var savedHost: HostConfiguration?
    public var phase: HostConnectionPhase { flow.phase }

    @ObservationIgnored private let flow: HostConnectionFlow
    /// 匯入或待配對時沿用的主機名稱。
    @ObservationIgnored private var presetName: String?
    @ObservationIgnored private var history: [Step] = []

    public init(
        store: any HostStore, credentials: HostCredentials = HostCredentials(), hostService: HostServiceAccess = HostServiceAccess(),
        existing: HostConfiguration? = nil,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel
    ) {
        flow = HostConnectionFlow(
            store: store, existing: existing, credentials: credentials, hostService: hostService, makeChannel: makeChannel)
    }

    /// 帶著資料進來:匯入(資料已齊直接到測試連線;HTTPS 分享連結沒有配對碼，到配對)或待配對(直接到配對)。
    public convenience init(
        store: any HostStore, credentials: HostCredentials = HostCredentials(), hostService: HostServiceAccess = HostServiceAccess(),
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?, @escaping SSHCredentialProvider) -> any HostChannel,
        shortcut: Shortcut
    ) throws {
        switch shortcut {
        case .needsPairing(let host):
            guard let address = host.hostService else { throw ShortcutError.needsEditor }
            self.init(store: store, credentials: credentials, hostService: hostService, existing: host, makeChannel: makeChannel)
            kind = .https
            presetName = host.name
            load(address)
            step = .pair
        case .importLink(let url):
            if HostServicePairingLink.isPairingLink(url) {
                let link = try HostServicePairingLink(url: url)
                self.init(store: store, credentials: credentials, hostService: hostService, makeChannel: makeChannel)
                kind = .https
                load(link.address)
                pairingCode = link.pairingCode
                step = .test
                return
            }
            let shared = try HostShareLink.decode(url)
            self.init(store: store, credentials: credentials, hostService: hostService, makeChannel: makeChannel)
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
                if let pin = shared.hostKeyPin { flow.accepted = (pin, shared.endpoint) }
                step = .test
            case .openSSH:
                throw ShortcutError.needsEditor
            }
        }
    }

    private func load(_ address: HostServiceAddress) {
        pairAddress = address.hostName
        pairPort = String(address.port)
    }

    // MARK: - 進度

    public var canGoBack: Bool { !history.isEmpty && step != .finished }

    /// 目前第幾步、共幾步(VoiceOver 與進度點)。
    public var progress: (position: Int, total: Int) {
        let path = kind == .https ? Self.httpsPath : Self.sshPath
        return ((path.firstIndex(of: step) ?? path.count - 1) + 1, path.count)
    }

    private static let sshPath: [Step] = [.kind, .system, .sshMethod, .enable, .details, .test]
    private static let httpsPath: [Step] = [.kind, .tailscale, .system, .install, .pair, .test]

    /// 目前這一頁的「下一步」按鈕能不能按(開啟 SSH 那頁一律可以)。
    public var canAdvance: Bool {
        switch step {
        case .enable, .tailscale, .install: true
        case .details: sshDraft != nil
        case .pair: httpsDraft != nil
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
        push(kind == .https ? .install : .sshMethod)
    }

    public func choose(_ method: SSHMethod) {
        sshMethod = method
        switch method {
        case .tailscale: push(.enable)
        case .native: handoff = .editor(.openSSH)
        }
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
        case .native?, nil:
            []
        }
    }

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
        let terminal = isWindows
            ? String(localized: "On that computer, open PowerShell, paste this line, then press Enter.")
            : String(localized: "On that computer, open Terminal, paste this line, then press Enter.")
        let command = isWindows
            ? "irm \(Self.hostServiceReleases)install.ps1 | iex"
            : "curl -fsSL \(Self.hostServiceReleases)install.sh | sh"
        return [AddHostGuideInstruction(text: terminal, command: command)]
    }

    /// 配對:讓電腦顯示 QR code。
    public var pairInstructions: [AddHostGuideInstruction] {
        [AddHostGuideInstruction(
            text: String(localized: "Paste this line too. A QR code appears on that computer."), command: "purrdr-host-service pair")]
    }

    /// 掃到的 QR code:是配對連結就帶入位址與配對碼並直接測試連線;不是就不動。
    @discardableResult
    public func applyScannedCode(_ text: String) -> Bool {
        guard step == .pair, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let link = try? HostServicePairingLink(url: url)
        else { return false }
        load(link.address)
        pairingCode = link.pairingCode
        push(.test)
        return true
    }

    /// 欄位旁「怎麼查」:在電腦上做的一步與可拷貝的指令。
    public func help(for field: Field) -> AddHostGuideInstruction? {
        let terminal = system == .windows
            ? String(localized: "On that computer, open PowerShell, paste this line, then press Enter.")
            : String(localized: "On that computer, open Terminal, paste this line, then press Enter.")
        switch field {
        case .address:
            guard sshMethod == .tailscale else { return nil }
            return AddHostGuideInstruction(
                text: String(localized: "\(terminal) Type the numbers that appear here."), command: "tailscale ip -4")
        case .username:
            return AddHostGuideInstruction(
                text: String(localized: "\(terminal) Type the name that appears here."),
                command: system == .windows ? "$env:USERNAME" : "whoami")
        case .port, .pairAddress, .pairPort, .pairingCode:
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
        case .enable: push(.details)
        case .details: push(.test)
        default: break
        }
    }

    public func back() {
        guard canGoBack, let previous = history.popLast() else { return }
        if step == .test { flow.cancelTest() }
        flow.phase = .editing
        handoff = nil
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
        history.removeAll()
        step = .finished
        return host
    }

    // MARK: - 內部

    private var draft: HostConnectionDraft? { kind == .https ? httpsDraft : sshDraft }

    private var httpsDraft: HostConnectionDraft? {
        let code = pairingCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty,
            let address = HostServiceAddress(addressField: pairAddress.trimmingCharacters(in: .whitespaces), portField: pairPort)
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
        return HostConnectionDraft(name: presetName ?? Self.defaultName(for: host), connection: .ssh(SSHConnectionDraft(settings: settings)))
    }

    /// 主機名稱的第一段(`studio.tail1234.ts.net` → `studio`);IP 位址整串當名稱。
    static func defaultName(for host: String) -> String {
        let isNumeric = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        guard !isNumeric, let first = host.split(separator: ".").first else { return host }
        return String(first)
    }
}
