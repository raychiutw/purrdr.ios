import Foundation
import Synchronization

/// HTTPS 連線方式的主機服務位址(ADR-0010):`https://<主機>.<tailnet>.ts.net`,只有 scheme、主機與埠。
///
/// 本機測試可用 `http://127.0.0.1:<埠>`(主機服務直接聽的位址，不經 `tailscale serve`);其他位址一律 https。
public struct HostServiceAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    /// 正規化後的位址，例如 `https://studio.tail1234.ts.net`。
    public let url: URL

    /// 接受 `studio.tail1234.ts.net`、`https://studio.tail1234.ts.net/`、`http://127.0.0.1:47820`;其他形式回傳 `nil`。
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        guard scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else { return nil }
        components.scheme = scheme
        components.host = host
        components.path = ""
        guard let url = components.url else { return nil }
        self.url = url
    }

    /// 主機名稱(顯示用)。
    public var hostName: String { url.host() ?? "" }

    /// 埠;沒寫時是 scheme 的預設埠。
    public var port: Int { url.port ?? (url.scheme == "http" ? 80 : 443) }

    /// WSS 連線的網址(`/v1/ws`);`http` 位址用 `ws`。
    public var webSocketURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = url.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/ws"
        return components.url!
    }

    /// 以配對碼換裝置權杖(`POST /v1/pair`)。
    public var pairURL: URL { url.appending(path: "v1/pair") }

    /// 裝置撤銷自己的權杖(`POST /v1/revoke`)。
    public var revokeURL: URL { url.appending(path: "v1/revoke") }

    public var description: String { url.absoluteString }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let address = HostServiceAddress(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a host service address"))
        }
        self = address
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
    }
}

/// 主機配對指令顯示的 QR code 內容:`purrdr://pair?address=<HTTPS 位址>&code=<配對碼>`。
public struct HostServicePairingLink: Sendable, Equatable {
    public var address: HostServiceAddress
    public var pairingCode: String

    public init(address: HostServiceAddress, pairingCode: String) {
        self.address = address
        self.pairingCode = pairingCode
    }

    public init(url: URL) throws(HostServicePairingLinkError) {
        guard url.scheme?.lowercased() == "purrdr", url.host()?.lowercased() == "pair" else { throw .notAPairingLink }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let address = items.first(where: { $0.name == "address" })?.value.flatMap(HostServiceAddress.init), !code.isEmpty
        else { throw .malformed }
        self.init(address: address, pairingCode: code)
    }

    /// 是不是配對連結(不檢查內容)。
    public static func isPairingLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "purrdr" && url.host()?.lowercased() == "pair"
    }
}

public enum HostServicePairingLinkError: Error, Equatable, Sendable {
    /// 不是 `purrdr://pair?…` 連結。
    case notAPairingLink
    /// 缺位址或配對碼，或位址不合法。
    case malformed
}

/// 連線配對成功：主機服務發給這支裝置的裝置權杖(GLOSSARY「裝置權杖」)。
public struct PairedDevice: Sendable, Equatable {
    public var deviceID: String
    public var deviceToken: String
    /// 唯讀裝置的寫入類操作會被主機服務拒絕。
    public var readOnly: Bool

    public init(deviceID: String, deviceToken: String, readOnly: Bool) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.readOnly = readOnly
    }
}

/// 存放每台 HTTPS 主機的裝置權杖。iOS 是 Keychain(`PurrdrFeatures.KeychainDeviceTokenStore`,僅此裝置、解鎖後、不同步)。
public protocol DeviceTokenStore: Sendable {
    func deviceToken(for host: UUID) throws -> String?
    /// `nil` 表示刪除。
    func setDeviceToken(_ token: String?, for host: UUID) throws
}

/// 只存在記憶體的裝置權杖：測試與 UI 測試模式(不碰 Keychain)使用。
public final class InMemoryDeviceTokenStore: DeviceTokenStore {
    private let tokens: Mutex<[UUID: String]>

    public init(tokens: [UUID: String] = [:]) {
        self.tokens = Mutex(tokens)
    }

    public func deviceToken(for host: UUID) throws -> String? {
        tokens.withLock { $0[host] }
    }

    public func setDeviceToken(_ token: String?, for host: UUID) throws {
        tokens.withLock { $0[host] = token }
    }
}

/// HTTPS 連線方式(主機服務)的錯誤。函式庫的錯誤字串不給使用者看，一律換成這裡的情況。
public enum HostServiceError: Error, Equatable, Sendable {
    /// 這支裝置沒有這台主機的裝置權杖(還沒配對，或權杖被刪了)。
    case notPaired
    /// 主機服務不認得這個裝置權杖(close code 4401)。
    case deviceTokenInvalid
    /// 這支裝置的權杖已在主機上撤銷(close code 4401)。
    case deviceTokenRevoked
    /// 配對碼不對或已用過。
    case pairingCodeInvalid
    /// 配對碼過期。
    case pairingCodeExpired
    /// 主機服務不支援這個 app 的協定版本。
    case protocolVersionUnsupported(supported: [Int])
    /// 主機服務連不到 herdr(herdr 沒在跑)。
    case herdrUnavailable
    /// herdr 伺服器太舊，沒有這個功能。
    case herdrCapabilityMissing
    /// 這支裝置配對成唯讀，不能做寫入類操作。
    case readOnlyDevice
    /// HTTPS 連線方式還不提供這個操作(herdr method 或功能名稱)。
    case unsupported(String)
    /// 找不到這個主機名稱(手機不在 tailnet,或位址打錯)。
    case hostNotFound
    /// 連不上主機(主機離線或不在 tailnet)。
    case unreachable
    /// 連得到主機，但主機服務沒在跑(`tailscale serve` 回 502)。
    case hostServiceNotRunning
    /// 連線中途斷了。主機可能已經執行，不會自動重送。
    case connectionLost
    /// 主機服務的回應讀不懂。
    case unexpectedResponse

    /// 要重新配對才能再連(權杖無效或已撤銷);不自動重連。
    public var requiresPairing: Bool {
        switch self {
        case .notPaired, .deviceTokenInvalid, .deviceTokenRevoked: true
        default: false
        }
    }
}
