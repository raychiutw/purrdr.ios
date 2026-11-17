import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import Security

/// HTTPS 主機(主機服務，ADR-0010)要用的東西：裝置權杖、連線配對與主機連線的建立方式。
public struct HostServiceAccess {
    public let tokens: any DeviceTokenStore
    public let pairing: HostServicePairing
    /// 顯示在主機裝置列表的名稱。
    public let deviceName: String
    /// 依位址與權杖來源建立主機連線(權杖在撥號時才讀)。
    public let makeConnection: @MainActor (HostServiceAddress, @escaping @Sendable () throws -> String?) -> any HostConnection

    public init(
        tokens: any DeviceTokenStore = InMemoryDeviceTokenStore(), pairing: HostServicePairing = HostServicePairing(),
        deviceName: String = "iPhone",
        makeConnection: @escaping @MainActor (HostServiceAddress, @escaping @Sendable () throws -> String?) -> any HostConnection = {
            HTTPSHostConnection(address: $0, deviceToken: $1)
        }
    ) {
        self.tokens = tokens
        self.pairing = pairing
        self.deviceName = deviceName
        self.makeConnection = makeConnection
    }

    /// 已存的 HTTPS 主機的連線。
    @MainActor
    func connection(for host: HostConfiguration, address: HostServiceAddress) -> any HostConnection {
        let tokens = tokens
        let id = host.id
        return makeConnection(address) { try tokens.deviceToken(for: id) }
    }
}

/// 裝置權杖存 Keychain:每台主機一個 generic password 項目，與主機設定、SSH 祕密分開。
/// 可存取等級「解鎖時、僅此裝置」,不經 iCloud 同步(GLOSSARY「裝置權杖」)。
public struct KeychainDeviceTokenStore: DeviceTokenStore {
    private let keychain: any KeychainAPI
    private let service: String

    public init(keychain: any KeychainAPI = SystemKeychain(), service: String = "com.raychiu.purrdr.device-token") {
        self.keychain = keychain
        self.service = service
    }

    public func deviceToken(for host: UUID) throws -> String? {
        var query = itemQuery(host)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setDeviceToken(_ token: String?, for host: UUID) throws {
        guard let token else {
            let status = keychain.delete(itemQuery(host))
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(token.utf8)
        var attributes = itemQuery(host)
        attributes[kSecValueData as String] = data
        // 可存取等級只能在新增項目時設定。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Purrdr device token"
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            let updated = keychain.update(itemQuery(host), [kSecValueData as String: data])
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func itemQuery(_ host: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// HTTPS 主機沒有主機通道：只有 SSH 才有的功能(登入 Shell、檔案、推播外掛、主題…)一律以 `unsupported` 失敗，不連網路。
struct HostServiceOnlyChannel: HostChannel {
    func execute(_ command: String) async throws -> any ExecSession {
        throw HostServiceError.unsupported("ssh")
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw HostServiceError.unsupported("ssh")
    }
}

extension HostServiceAccess {
    /// 正式 app:權杖存 Keychain,連線經 `URLSession`(系統 TLS)。
    public static func system(deviceName: String, appVersion: String?) -> HostServiceAccess {
        HostServiceAccess(tokens: KeychainDeviceTokenStore(), deviceName: deviceName) {
            HTTPSHostConnection(address: $0, deviceToken: $1, appVersion: appVersion)
        }
    }

    /// UI 測試：不連網路、權杖只在記憶體。配對碼 `K7QM-2XPA` 換得權杖、`OLD0-CODE` 過期、其他不對;
    /// HTTPS 主機的連線是包住 `channel`(Demo 主機)的主機連線，畫面看到 Demo 的 Agent。
    public static func uiTesting(channel: any HostChannel) -> HostServiceAccess {
        HostServiceAccess(pairing: HostServicePairing(http: UITestingHostServiceHTTP()), deviceName: "iPhone") { _, _ in
            SSHHostConnection(channel: channel)
        }
    }
}

/// UI 測試的配對與撤銷：照協定回應，不連網路。
private struct UITestingHostServiceHTTP: HostServiceHTTPSending {
    func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse {
        if url.path() == "/v1/revoke" { return HostServiceHTTPResponse(status: 204, body: Data()) }
        let code = body.flatMap { try? JSONDecoder().decode(HostServiceProtocol.PairRequest.self, from: $0) }?.pairingCode
        switch code?.uppercased() {
        case "K7QM-2XPA":
            let paired = HostServiceProtocol.PairResponse(deviceId: "ui-testing", deviceToken: "ui-testing-token", readOnly: false)
            return HostServiceHTTPResponse(status: 200, body: try JSONEncoder().encode(paired))
        case "OLD0-CODE":
            return try Self.error(.pairingCodeExpired)
        default:
            return try Self.error(.pairingCodeInvalid)
        }
    }

    private static func error(_ code: HostServiceProtocol.ErrorCode) throws -> HostServiceHTTPResponse {
        let message = HostServiceProtocol.ServerMessage.errorMessage(.init(code: code, message: code.rawValue))
        return HostServiceHTTPResponse(status: 401, body: try JSONEncoder().encode(message))
    }
}
