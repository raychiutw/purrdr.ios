import Foundation
import PurrdrCore

/// 連線與 herdr 錯誤的白話說明。函式庫的錯誤字串不給使用者看(行為規格 §7.6)。
package enum HostErrorText {
    /// - Parameters:
    ///   - connection: 知道連線方式時(主機編輯器)給更具體的說明;不知道時用兩種方式都適用的說法。
    ///   - authentication: OpenSSH 的登入方式。
    package static func message(
        for error: any Error, connection: HostConfiguration.ConnectionMethod? = nil,
        authentication: HostConfiguration.OpenSSHAuthentication? = nil
    ) -> String {
        switch error {
        case SSHConnectionError.authenticationFailed:
            authenticationFailed(connection: connection, authentication: authentication)
        case SSHConnectionError.authenticationMethodNotAccepted:
            switch authentication {
            case .password?:
                String(localized: "This host doesn’t accept password sign-in. Use a key instead, or turn on password sign-in on the host.")
            default:
                String(localized: "This host doesn’t accept key sign-in. Use a password instead, or turn on key sign-in on the host.")
            }
        case SSHConnectionError.connectionRefused:
            connection == .openSSH
                ? String(localized: "The host refused the connection. Check that Remote Login is on.")
                : String(localized: "The host refused the connection. Check that Tailscale is on, on the host.")
        case HostCredentialError.missingSecret:
            String(localized: "This host’s password or key isn’t on this device. Edit the host and enter it again.")
        case DeviceKeyError.secureEnclaveUnavailable:
            String(localized: "This device can’t create a key. Import a key or use a password.")
        case let error as SSHKeyImportError:
            keyImportMessage(error)
        case let error as HostServiceError:
            hostServiceMessage(error)
        default:
            commonMessage(for: error)
        }
    }

    /// 匯入私鑰失敗的說明。
    package static func keyImportMessage(_ error: SSHKeyImportError) -> String {
        switch error {
        case .rsaNotSupported:
            String(localized: "This kind of key isn’t supported. Use this device’s key instead.")
        case .unsupportedKeyType(let type):
            String(localized: "\(type) keys aren’t supported. Use this device’s key instead.")
        case .unsupportedFormat:
            String(localized: "This isn’t an OpenSSH private key. Paste the whole file, starting with “-----BEGIN OPENSSH PRIVATE KEY-----”. To convert an older key, run ssh-keygen -p -f on it.")
        case .publicKeyInsteadOfPrivate:
            String(localized: "This is a public key. Paste the private key file instead (the one without .pub).")
        case .passphraseProtected:
            // 只用系統加密，不解 passphrase(見 SSHKeyImportError.passphraseProtected)。
            String(localized: "This key has a passphrase, which isn’t supported. On your computer, run this, then paste the key again: ssh-keygen -p -N \"\" -f <key file>")
        case .malformed:
            String(localized: "This key is incomplete or damaged. Paste the whole file again.")
        }
    }

    private static func authenticationFailed(
        connection: HostConfiguration.ConnectionMethod?, authentication: HostConfiguration.OpenSSHAuthentication?
    ) -> String {
        switch (connection, authentication) {
        case (.tailscaleSSH?, _):
            String(localized: "Tailscale didn’t let this account sign in. Check the account name and your Tailscale settings.")
        case (.openSSH?, .password?):
            String(localized: "The host didn’t accept this account name and password.")
        case (.openSSH?, .deviceKey?):
            String(localized: "The host didn’t accept this device. Add this device’s key to the host again, and check the account name.")
        case (.openSSH?, _):
            String(localized: "The host didn’t accept this key. Make sure it was added to the host, and check the account name.")
        case (nil, _), (.https?, _):
            String(localized: "The host didn’t let this account sign in. Edit the host to check the account name and sign-in method.")
        }
    }

    /// HTTPS 連線方式(主機服務)的說明。權杖失效時引導重新配對。
    package static func hostServiceMessage(_ error: HostServiceError) -> String {
        switch error {
        case .notPaired:
            String(localized: "This device isn’t paired with this host. Edit the host and pair again with a new pairing code.")
        case .deviceTokenInvalid:
            String(localized: "The host doesn’t recognize this device anymore. Edit the host and pair again with a new pairing code.")
        case .deviceTokenRevoked:
            String(localized: "This device was removed from the host. Edit the host and pair again with a new code.")
        case .pairingCodeInvalid:
            String(localized: "This pairing code isn’t valid or was already used. On the host, run purrdr-host-service pair again for a new code.")
        case .pairingCodeExpired:
            String(localized: "This pairing code expired. On the host, run purrdr-host-service pair again for a new code.")
        case .protocolVersionUnsupported(let supported) where supported.max().map({ $0 < HostServiceProtocol.version }) == true:
            String(localized: "The Purrdr host service on this host is older than this version of Purrdr. Update the host service on the host.")
        case .protocolVersionUnsupported(let supported) where supported.min().map({ $0 > HostServiceProtocol.version }) == true:
            String(localized: "The Purrdr host service on this host is newer than this version of Purrdr. Update Purrdr.")
        case .protocolVersionUnsupported:
            String(localized: "The Purrdr host service on this host doesn’t match this version of Purrdr. Update Purrdr and the host service.")
        case .herdrUnavailable:
            String(localized: "The host service can’t reach herdr. Start herdr on the host, then try again.")
        case .herdrCapabilityMissing:
            String(localized: "herdr on this host is too old for this. Update herdr, then restart it.")
        case .readOnlyDevice:
            String(localized: "This device is paired read-only, so it can’t send anything to this host.")
        case .deviceUnknown:
            String(localized: "This host doesn’t have that device anymore. Refresh the list.")
        case .unsupported:
            String(localized: "This isn’t available over HTTPS yet.")
        case .hostServiceUpdateRequired(_, let installedVersion?):
            String(localized: "This needs a newer Purrdr host service (this host has \(installedVersion)). Update the host service on the host; Hosts shows the command.")
        case .hostServiceUpdateRequired(_, nil):
            String(localized: "This needs a newer Purrdr host service. Update the host service on the host; Hosts shows the command.")
        case .hostNotFound:
            String(localized: "Couldn’t find this host. Check the address, and that Tailscale is on for this device.")
        case .notOnTailnet:
            String(localized: "Tailscale is off on this device. Turn it on, then try again.")
        case .unreachable:
            String(localized: "The host didn’t answer. Make sure it’s awake and connected to Tailscale.")
        case .hostServiceNotRunning:
            String(localized: "The host is reachable, but the Purrdr host service isn’t running. Start it on the host, then try again.")
        case .connectionLost:
            String(localized: "The connection dropped. Try again.")
        case .unexpectedResponse:
            String(localized: "The host service sent a response Purrdr doesn’t understand. Update Purrdr and the host service.")
        case .paneChanged:
            String(localized: "This chat changed on the host, so nothing was sent.")
        case .queueFull:
            String(localized: "The Send When Done queue is full (20 messages). Wait for some to send or delete one.")
        case .queueItemUnknown:
            String(localized: "That message already left the queue. Refreshing the list.")
        }
    }

    private static func commonMessage(for error: any Error) -> String {
        switch error {
        case SSHConnectionError.hostKeyChanged:
            String(localized: "This host looks different from before. If you didn’t reinstall or reset it, stop and check it in Hosts.")
        case SSHConnectionError.hostKeyUnverified:
            String(localized: "This host hasn’t been confirmed yet. Test the connection in Hosts.")
        case SSHConnectionError.hostNotFound:
            String(localized: "Couldn’t find this host. Check the address, and that Tailscale is on for this device.")
        case SSHConnectionError.timedOut:
            String(localized: "The host didn’t answer in time. Make sure it’s awake and Tailscale is on for both devices.")
        case SSHConnectionError.unreachable:
            String(localized: "Couldn’t reach this host. Make sure Tailscale is on for both devices.")
        case SSHConnectionError.tailscaleCheckCancelled:
            String(localized: "Tailscale sign-in was canceled. Try again when you’re ready to sign in.")
        case SSHConnectionError.tailscaleCheckTimedOut:
            String(localized: "The Tailscale sign-in wasn’t finished in time. Try again.")
        case SSHConnectionError.connectionLost, SSHConnectionError.channelRejected:
            String(localized: "The connection dropped. Try again.")
        case HostProbeError.herdrNotInstalled:
            String(localized: "herdr isn’t installed on this host, or it isn’t at the saved location.")
        case HostProbeError.notHerdr:
            String(localized: "The herdr path runs a different program. Check the herdr path.")
        case HostProbeError.serverNotRunning:
            String(localized: "herdr isn’t running on this host. Open herdr there, then test again.")
        case HostProbeError.unsupportedOperatingSystem:
            String(localized: "Purrdr supports macOS, Linux, and Windows hosts.")
        case WindowsCommandError.unsupported:
            String(localized: "This isn’t available on Windows hosts yet.")
        case WindowsCommandError.commandTooLong:
            String(localized: "This request is too long for a Windows host.")
        case HostProbeError.herdr(let message):
            message
        case HostProbeError.updateFailed(let message):
            String(localized: "Couldn’t update herdr. \(message)")
        default:
            String(localized: "Couldn’t reach this host. Try again.")
        }
    }
}

/// Windows 主機還沒有 PowerShell 版本的功能(主題、用量等以 `localizedDescription` 顯示錯誤的地方)。
extension WindowsCommandError: LocalizedError {
    public var errorDescription: String? { HostErrorText.message(for: self) }
}
