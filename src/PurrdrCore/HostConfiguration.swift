import Foundation

/// 一台已存的主機(GLOSSARY「主機」):怎麼連(連線方式與它自己的欄位)、主機的作業系統。
public struct HostConfiguration: Sendable, Hashable, Identifiable {
    /// GLOSSARY「連線方式」的種類(畫面選項、主機同步與分享連結的 wire 值)。
    public enum ConnectionMethod: String, Sendable, Hashable, Codable {
        /// Tailscale SSH:依 tailnet 身分放行(`none` 認證)。
        case tailscaleSSH
        /// 主機自己的 sshd,用金鑰或密碼登入。
        case openSSH
        /// 經 Tailscale Serve 連到主機服務，用裝置權杖(ADR-0010)。不支援登入 Shell。
        case https

        /// 經主機服務連線(沒有 SSH 端點、herdr 設定與 host key pin)。只有種類、還沒有完整主機設定的地方(編輯器畫面、wire)用。
        public var usesHostService: Bool { self == .https }
    }

    /// OpenSSH 主機用什麼登入。祕密(密碼、匯入的私鑰與 passphrase)不在主機設定裡，另存 Keychain。
    public enum OpenSSHAuthentication: String, Sendable, Hashable, Codable, CaseIterable {
        /// 這支裝置在 Secure Enclave 產生的金鑰。私鑰不離開 Secure Enclave。
        case deviceKey
        /// 匯入的 ed25519／ECDSA 私鑰。
        case importedKey
        case password
    }

    /// SSH 連線方式共有的欄位：連到哪裡、herdr 在哪、信任哪把 host key。
    public struct SSHSettings: Sendable, Hashable {
        public var endpoint: SSHEndpoint
        public var herdr: HerdrInstallation
        /// 使用者確認過的 host key 指紋。空的指紋永遠不存(行為規格 §8.2)。
        public var hostKeyPin: HostKeyFingerprint?

        public init(endpoint: SSHEndpoint, herdr: HerdrInstallation = HerdrInstallation(), hostKeyPin: HostKeyFingerprint? = nil) {
            self.endpoint = endpoint
            self.herdr = herdr
            self.hostKeyPin = hostKeyPin
        }
    }

    /// 連線方式與只屬於它的欄位。
    public enum Connection: Sendable, Hashable {
        case tailscaleSSH(SSHSettings)
        case openSSH(SSHSettings, authentication: OpenSSHAuthentication)
        /// 主機服務位址;裝置權杖不在這裡，另存 Keychain。
        case https(HostServiceAddress)

        public var method: ConnectionMethod {
            switch self {
            case .tailscaleSSH: .tailscaleSSH
            case .openSSH: .openSSH
            case .https: .https
            }
        }

        /// SSH 連線方式的欄位;HTTPS 為 `nil`。
        public var ssh: SSHSettings? {
            switch self {
            case .tailscaleSSH(let settings), .openSSH(let settings, _): settings
            case .https: nil
            }
        }

        /// OpenSSH 的登入方式;其他連線方式為 `nil`。
        public var authentication: OpenSSHAuthentication? {
            if case .openSSH(_, let authentication) = self { return authentication }
            return nil
        }

        /// HTTPS 的主機服務位址;SSH 為 `nil`。
        public var hostService: HostServiceAddress? {
            if case .https(let address) = self { return address }
            return nil
        }
    }

    public var id: UUID
    public var name: String
    public var connection: Connection
    /// 連線測試偵測到的作業系統。
    public var operatingSystem: HostOperatingSystem?
    /// 這台主機啟用的 Agent(#477,`HostAgentSettings`):只有啟用的才查用量、才出現在新增聊天。
    /// `nil` 是還沒設定過(舊版 app 存的主機);只存在這支裝置的 Keychain,不同步。
    public var enabledAgents: Set<AgentID>?

    public init(
        id: UUID = UUID(), name: String, connection: Connection, operatingSystem: HostOperatingSystem? = nil,
        enabledAgents: Set<AgentID>? = nil
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.operatingSystem = operatingSystem
        self.enabledAgents = enabledAgents
    }

    /// SSH 主機：`openSSH` 是 OpenSSH 的登入方式，`nil` 是 Tailscale SSH。
    public init(
        id: UUID = UUID(), name: String, endpoint: SSHEndpoint, openSSH authentication: OpenSSHAuthentication? = nil,
        herdr: HerdrInstallation = HerdrInstallation(), operatingSystem: HostOperatingSystem? = nil, hostKeyPin: HostKeyFingerprint? = nil
    ) {
        let settings = SSHSettings(endpoint: endpoint, herdr: herdr, hostKeyPin: hostKeyPin)
        let connection: Connection = authentication.map { .openSSH(settings, authentication: $0) } ?? .tailscaleSSH(settings)
        self.init(id: id, name: name, connection: connection, operatingSystem: operatingSystem)
    }

    /// HTTPS 主機。
    public init(id: UUID = UUID(), name: String, hostService: HostServiceAddress) {
        self.init(id: id, name: name, connection: .https(hostService))
    }

    public var connectionMethod: ConnectionMethod { connection.method }
    /// SSH 連線方式的欄位;HTTPS 為 `nil`。
    public var ssh: SSHSettings? { connection.ssh }
    /// OpenSSH 的登入方式;其他連線方式為 `nil`。
    public var authentication: OpenSSHAuthentication? { connection.authentication }
    /// HTTPS 的主機服務位址;SSH 為 `nil`。
    public var hostService: HostServiceAddress? { connection.hostService }

    /// 有沒有登入 Shell 與檔案(SSH 才有)。
    public var supportsLoginShell: Bool { connection.ssh != nil }
}

// MARK: - Keychain 儲存格式

/// 新格式把連線方式放在 `connection`;同時寫出 0.36 以前的攤平欄位，讓舊版 app 仍讀得懂(#149)。
/// 讀取時有 `connection` 就以它為準，沒有就從攤平欄位遷移。
extension HostConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, operatingSystem, connection, enabledAgents
        case endpoint, connectionMethod, authentication, herdr, hostKeyPin, hostService
    }

    private enum ConnectionKeys: String, CodingKey {
        case method, endpoint, herdr, hostKeyPin, authentication, hostService
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        operatingSystem = try container.decodeIfPresent(HostOperatingSystem.self, forKey: .operatingSystem)
        enabledAgents = try container.decodeIfPresent([String].self, forKey: .enabledAgents).map { Set($0.map(AgentID.init(herdrName:))) }
        if container.contains(.connection) {
            let nested = try container.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .connection)
            connection = try Self.connection(
                method: nested.decode(ConnectionMethod.self, forKey: .method), fields: nested, defaultAuthentication: nil)
        } else {
            // 舊格式的欄位名稱與新格式相同，只是攤平在最外層;OpenSSH 可能沒有登入方式(當時預設這支裝置的金鑰)。
            connection = try Self.connection(
                method: container.decode(ConnectionMethod.self, forKey: .connectionMethod),
                fields: decoder.container(keyedBy: ConnectionKeys.self), defaultAuthentication: .deviceKey)
        }
    }

    private static func connection(
        method: ConnectionMethod, fields: KeyedDecodingContainer<ConnectionKeys>, defaultAuthentication: OpenSSHAuthentication?
    ) throws -> Connection {
        if method == .https { return .https(try fields.decode(HostServiceAddress.self, forKey: .hostService)) }
        let settings = SSHSettings(
            endpoint: try fields.decode(SSHEndpoint.self, forKey: .endpoint),
            herdr: try fields.decodeIfPresent(HerdrInstallation.self, forKey: .herdr) ?? HerdrInstallation(),
            hostKeyPin: try fields.decodeIfPresent(HostKeyFingerprint.self, forKey: .hostKeyPin))
        guard method == .openSSH else { return .tailscaleSSH(settings) }
        let decoded = try fields.decodeIfPresent(OpenSSHAuthentication.self, forKey: .authentication)
        guard let authentication = decoded ?? defaultAuthentication else {
            throw DecodingError.keyNotFound(
                ConnectionKeys.authentication, .init(codingPath: fields.codingPath, debugDescription: "OpenSSH 沒有登入方式"))
        }
        return .openSSH(settings, authentication: authentication)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(operatingSystem, forKey: .operatingSystem)
        try container.encodeIfPresent(enabledAgents.map { $0.map(\.canonicalName).sorted() }, forKey: .enabledAgents)
        var nested = container.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .connection)
        try nested.encode(connection.method, forKey: .method)
        if let settings = connection.ssh {
            try nested.encode(settings.endpoint, forKey: .endpoint)
            try nested.encode(settings.herdr, forKey: .herdr)
            try nested.encodeIfPresent(settings.hostKeyPin, forKey: .hostKeyPin)
        }
        try nested.encodeIfPresent(connection.authentication, forKey: .authentication)
        try nested.encodeIfPresent(connection.hostService, forKey: .hostService)
        try encodeLegacyFields(into: &container)
    }

    /// 0.36 的攤平欄位(舊版 app 的 `endpoint`、`herdr` 是必填):HTTPS 的端點是主機服務的主機名稱與埠。
    private func encodeLegacyFields(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(connection.ssh?.endpoint ?? connection.hostService?.legacyEndpoint, forKey: .endpoint)
        try container.encode(connection.method, forKey: .connectionMethod)
        try container.encodeIfPresent(connection.authentication, forKey: .authentication)
        try container.encode(connection.ssh?.herdr ?? HerdrInstallation(), forKey: .herdr)
        try container.encodeIfPresent(connection.ssh?.hostKeyPin, forKey: .hostKeyPin)
        try container.encodeIfPresent(connection.hostService, forKey: .hostService)
    }
}
