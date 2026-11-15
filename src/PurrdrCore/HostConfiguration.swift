import Foundation

/// 一台已存的主機(GLOSSARY「主機」):怎麼連、以誰登入、herdr 在哪、信任哪把 host key。
public struct HostConfiguration: Sendable, Hashable, Codable, Identifiable {
    /// GLOSSARY「連線方式」。OpenSSH 在 #8 加入。
    public enum ConnectionMethod: String, Sendable, Hashable, Codable {
        case tailscaleSSH
    }

    public var id: UUID
    public var name: String
    public var endpoint: SSHEndpoint
    public var connectionMethod: ConnectionMethod
    public var herdr: HerdrInstallation
    /// 連線測試偵測到的作業系統。
    public var operatingSystem: HostOperatingSystem?
    /// 使用者確認過的 host key 指紋。空的指紋永遠不存(行為規格 §8.2)。
    public var hostKeyPin: HostKeyFingerprint?

    public init(
        id: UUID = UUID(), name: String, endpoint: SSHEndpoint, connectionMethod: ConnectionMethod = .tailscaleSSH,
        herdr: HerdrInstallation = HerdrInstallation(), operatingSystem: HostOperatingSystem? = nil, hostKeyPin: HostKeyFingerprint? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.connectionMethod = connectionMethod
        self.herdr = herdr
        self.operatingSystem = operatingSystem
        self.hostKeyPin = hostKeyPin
    }
}
