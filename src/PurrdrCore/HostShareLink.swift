import Foundation

/// 分享出去的主機設定(QR code 與分享連結的內容)。
///
/// 刻意是獨立的型別，不直接編碼 `HostConfiguration`:主機設定之後加入密碼、私鑰、passphrase 時，
/// 分享內容不會跟著多出祕密。host key 指紋是公開資訊，一起分享(GLOSSARY「主機同步」同樣帶指紋)。
public struct SharedHost: Sendable, Equatable {
    public var name: String
    public var endpoint: SSHEndpoint
    public var connectionMethod: HostConfiguration.ConnectionMethod
    public var herdr: HerdrInstallation
    public var hostKeyPin: HostKeyFingerprint?

    public init(
        name: String, endpoint: SSHEndpoint, connectionMethod: HostConfiguration.ConnectionMethod = .tailscaleSSH,
        herdr: HerdrInstallation = HerdrInstallation(), hostKeyPin: HostKeyFingerprint? = nil
    ) {
        self.name = name
        self.endpoint = endpoint
        self.connectionMethod = connectionMethod
        self.herdr = herdr
        self.hostKeyPin = hostKeyPin
    }

    public init(_ host: HostConfiguration) {
        self.init(
            name: host.name, endpoint: host.endpoint, connectionMethod: host.connectionMethod, herdr: host.herdr,
            hostKeyPin: host.hostKeyPin)
    }
}

public enum HostShareLinkError: Error, Equatable, Sendable {
    /// 不是 `purrdr://host?d=…` 形式的連結。
    case notAHostLink
    /// 內容讀不懂或欄位不合法。
    case malformed
    /// 之後版本的 app 產生的連結。
    case unsupportedVersion
}

/// 主機分享連結:`purrdr://host?d=<base64url JSON>`。QR code 的內容就是這個連結，
/// 用系統相機掃描或點分享連結都會開啟 app 匯入(匯入後仍要通過連線測試才儲存)。
public enum HostShareLink {
    static let version = 1

    public static func url(for host: HostConfiguration) -> URL {
        url(for: SharedHost(host))
    }

    public static func url(for host: SharedHost) -> URL {
        let wire = Wire(
            v: version, name: host.name, host: host.endpoint.host, port: host.endpoint.port, user: host.endpoint.username,
            method: host.connectionMethod.rawValue, herdr: host.herdr.path == "herdr" ? nil : host.herdr.path,
            session: host.herdr.session, pin: host.hostKeyPin?.stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // 只有字串與整數，編碼不會失敗。
        let data = (try? encoder.encode(wire)) ?? Data()
        var components = URLComponents()
        components.scheme = "purrdr"
        components.host = "host"
        components.queryItems = [URLQueryItem(name: "d", value: base64URL(data))]
        return components.url!
    }

    public static func decode(_ url: URL) throws -> SharedHost {
        guard url.scheme?.lowercased() == "purrdr", url.host()?.lowercased() == "host" else { throw HostShareLinkError.notAHostLink }
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = fromBase64URL(value)
        else { throw HostShareLinkError.malformed }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw HostShareLinkError.malformed }
        guard header.v == version else { throw HostShareLinkError.unsupportedVersion }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw HostShareLinkError.malformed }
        let name = wire.name.trimmingCharacters(in: .whitespaces)
        let host = wire.host.trimmingCharacters(in: .whitespaces)
        let user = wire.user.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !host.isEmpty, !user.isEmpty, (1...65_535).contains(wire.port) else { throw HostShareLinkError.malformed }
        let method: HostConfiguration.ConnectionMethod
        if let raw = wire.method {
            guard let known = HostConfiguration.ConnectionMethod(rawValue: raw) else { throw HostShareLinkError.malformed }
            method = known
        } else {
            method = .tailscaleSSH
        }
        return SharedHost(
            name: name, endpoint: SSHEndpoint(host: host, port: wire.port, username: user), connectionMethod: method,
            herdr: HerdrInstallation(path: wire.herdr ?? "herdr", session: wire.session),
            hostKeyPin: wire.pin.flatMap(HostKeyFingerprint.init(stored:)))
    }

    // MARK: - wire format(只在這裡)

    private struct Header: Decodable {
        var v: Int
    }

    /// 欄位白名單。新增欄位前先想清楚：分享內容永不放祕密。
    private struct Wire: Codable {
        var v: Int
        var name: String
        var host: String
        var port: Int
        var user: String
        var method: String?
        var herdr: String?
        var session: String?
        var pin: String?
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func fromBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
