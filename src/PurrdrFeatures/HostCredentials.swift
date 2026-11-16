import Foundation
import PurrdrCore

public enum HostCredentialError: Error, Equatable {
    /// 主機設定在，但這台主機的密碼或私鑰不在這支裝置上(例如從備份還原)。不要用空密碼去試(行為規格 §8.1)。
    case missingSecret
}

/// 依主機設定決定登入用的憑證：Tailscale SSH 用 `none`、OpenSSH 依登入方式讀祕密或裝置金鑰。
///
/// 回傳的憑證來源在撥號時才讀 Keychain(行為規格 §7.1 lazy)。
public struct HostCredentials: Sendable {
    public let secrets: any HostSecretStore
    public let deviceKey: any DeviceKey

    public init(secrets: any HostSecretStore = EphemeralHostSecretStore(), deviceKey: any DeviceKey = EphemeralDeviceKey()) {
        self.secrets = secrets
        self.deviceKey = deviceKey
    }

    /// 已存主機的憑證來源。
    public func provider(for host: HostConfiguration) -> SSHCredentialProvider {
        provider(method: host.connectionMethod, authentication: host.authentication, hostID: host.id, entered: nil)
    }

    /// - Parameter entered: 編輯器裡剛輸入、還沒存的祕密;`nil` 時讀已存的。
    func provider(
        method: HostConfiguration.ConnectionMethod, authentication: HostConfiguration.OpenSSHAuthentication?,
        hostID: UUID?, entered: HostSecret?
    ) -> SSHCredentialProvider {
        { [secrets, deviceKey] in
            guard method == .openSSH, let authentication else { return .none }
            if authentication == .deviceKey { return .privateKey(try deviceKey.signingKey()) }
            guard let secret = try entered ?? hostID.flatMap({ try secrets.secret(for: $0) }) else {
                throw HostCredentialError.missingSecret
            }
            switch (authentication, secret) {
            case (.password, .password(let password)):
                return .password(password)
            case (.importedKey, .privateKey(let text, _)):
                return .privateKey(try SSHPrivateKey(openSSH: text))
            default:
                // 存的祕密與登入方式對不上(例如改了方式但沒存新的祕密)。
                throw HostCredentialError.missingSecret
            }
        }
    }
}
