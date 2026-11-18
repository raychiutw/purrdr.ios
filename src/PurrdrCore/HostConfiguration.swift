import Foundation

/// 一台已存的主機(GLOSSARY「主機」):怎麼連、以誰登入、herdr 在哪、信任哪把 host key。
public struct HostConfiguration: Sendable, Hashable, Codable, Identifiable {
    /// GLOSSARY「連線方式」。
    public enum ConnectionMethod: String, Sendable, Hashable, Codable {
        /// Tailscale SSH:依 tailnet 身分放行(`none` 認證)。
        case tailscaleSSH
        /// 主機自己的 sshd,用金鑰或密碼登入。
        case openSSH
        /// 經 Tailscale Serve 連到主機服務，用裝置權杖(ADR-0010)。不支援登入 Shell。
        case https

        /// 經主機服務連線(HTTPS):沒有 SSH,所以沒有登入 Shell、檔案與 herdr 更新。
        public var usesHostService: Bool { self == .https }

        /// 這種連線方式帶的主機服務位址：只有 HTTPS 帶，SSH 一律 `nil`。主機設定、分享與同步都經這裡。
        public func hostService(_ address: HostServiceAddress?) -> HostServiceAddress? {
            usesHostService ? address : nil
        }
    }

    /// OpenSSH 主機用什麼登入。祕密(密碼、匯入的私鑰與 passphrase)不在主機設定裡，另存 Keychain。
    public enum OpenSSHAuthentication: String, Sendable, Hashable, Codable, CaseIterable {
        /// 這支裝置在 Secure Enclave 產生的金鑰。私鑰不離開 Secure Enclave。
        case deviceKey
        /// 匯入的 ed25519／ECDSA 私鑰。
        case importedKey
        case password
    }

    public var id: UUID
    public var name: String
    public var endpoint: SSHEndpoint
    public var connectionMethod: ConnectionMethod
    /// OpenSSH 主機的登入方式;Tailscale SSH 為 `nil`。
    public var authentication: OpenSSHAuthentication?
    public var herdr: HerdrInstallation
    /// 連線測試偵測到的作業系統。
    public var operatingSystem: HostOperatingSystem?
    /// 使用者確認過的 host key 指紋。空的指紋永遠不存(行為規格 §8.2)。
    public var hostKeyPin: HostKeyFingerprint?
    /// HTTPS 主機的主機服務位址;SSH 主機為 `nil`。裝置權杖不在這裡，另存 Keychain。
    public var hostService: HostServiceAddress?

    public init(
        id: UUID = UUID(), name: String, endpoint: SSHEndpoint, connectionMethod: ConnectionMethod = .tailscaleSSH,
        authentication: OpenSSHAuthentication? = nil, herdr: HerdrInstallation = HerdrInstallation(),
        operatingSystem: HostOperatingSystem? = nil, hostKeyPin: HostKeyFingerprint? = nil, hostService: HostServiceAddress? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.connectionMethod = connectionMethod
        self.authentication = connectionMethod == .openSSH ? authentication : nil
        self.herdr = herdr
        self.operatingSystem = operatingSystem
        self.hostKeyPin = hostKeyPin
        self.hostService = connectionMethod.hostService(hostService)
    }

    /// HTTPS 主機：端點只記主機名稱與埠(顯示用，不登入)。
    public init(id: UUID = UUID(), name: String, hostService: HostServiceAddress) {
        self.init(
            id: id, name: name, endpoint: SSHEndpoint(host: hostService.hostName, port: hostService.port, username: ""),
            connectionMethod: .https, hostService: hostService)
    }

    /// 有沒有登入 Shell 與檔案(SSH 才有)。
    public var supportsLoginShell: Bool { !connectionMethod.usesHostService }
}
