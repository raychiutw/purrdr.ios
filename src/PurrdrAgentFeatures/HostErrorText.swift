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
                String(localized: "This computer doesn’t accept password sign-in. Use a key instead, or turn on password sign-in on that computer.")
            default:
                String(localized: "This computer doesn’t accept key sign-in. Use a password instead, or turn on key sign-in on that computer.")
            }
        case SSHConnectionError.connectionRefused:
            connection == .openSSH
                ? String(localized: "The computer refused the connection. Check that Remote Login is on.")
                : String(localized: "The computer refused the connection. Check that Tailscale is on, on that computer.")
        case HostCredentialError.missingSecret:
            String(localized: "This computer’s password or key isn’t on this device. Edit the computer and enter it again.")
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
            String(localized: "The computer didn’t accept this account name and password.")
        case (.openSSH?, .deviceKey?):
            String(localized: "The computer didn’t accept this device. Add this device’s key to the computer again, and check the account name.")
        case (.openSSH?, _):
            String(localized: "The computer didn’t accept this key. Make sure it was added to the computer, and check the account name.")
        case (nil, _), (.https?, _):
            String(localized: "The computer didn’t let this account sign in. Edit the computer to check the account name and sign-in method.")
        }
    }

    /// HTTPS 連線方式(主機服務)的說明。權杖失效時引導重新配對。
    package static func hostServiceMessage(_ error: HostServiceError) -> String {
        switch error {
        case .notPaired:
            String(localized: "This device isn’t paired with this computer. Edit the computer and pair again with a new pairing code.")
        case .deviceTokenInvalid:
            String(localized: "The computer doesn’t recognize this device anymore. Edit the computer and pair again with a new pairing code.")
        case .deviceTokenRevoked:
            String(localized: "This device was removed from the computer. Edit the computer and pair again with a new code.")
        case .pairingCodeInvalid:
            String(localized: "This pairing code isn’t valid or was already used. On that computer, run purrdr-host-service pair again for a new code.")
        case .pairingCodeExpired:
            String(localized: "This pairing code expired. On that computer, run purrdr-host-service pair again for a new code.")
        case .protocolVersionUnsupported(let supported) where supported.max().map({ $0 < HostServiceProtocol.version }) == true:
            String(localized: "The Purrdr host service on this computer is older than this version of Purrdr. Update the host service on the computer.")
        case .protocolVersionUnsupported(let supported) where supported.min().map({ $0 > HostServiceProtocol.version }) == true:
            String(localized: "The Purrdr host service on this computer is newer than this version of Purrdr. Update Purrdr.")
        case .protocolVersionUnsupported:
            String(localized: "The Purrdr host service on this computer doesn’t match this version of Purrdr. Update Purrdr and the host service.")
        case .herdrUnavailable:
            String(localized: "The host service can’t reach herdr. Start herdr on the computer, then try again.")
        case .herdrCapabilityMissing:
            String(localized: "herdr on this computer is too old for this. Update herdr, then restart it.")
        case .readOnlyDevice:
            String(localized: "This device is paired read-only, so it can’t send anything to this computer.")
        case .deviceUnknown:
            String(localized: "This computer doesn’t have that device anymore. Refresh the list.")
        case .unsupported:
            String(localized: "This isn’t available over HTTPS yet.")
        case .hostServiceUpdateRequired(_, let installedVersion?):
            String(localized: "This needs a newer Purrdr host service (this computer has \(installedVersion)). Update the host service on the computer; Computers shows the command.")
        case .hostServiceUpdateRequired(_, nil):
            String(localized: "This needs a newer Purrdr host service. Update the host service on the computer; Computers shows the command.")
        case .hostNotFound:
            String(localized: "Couldn’t find this computer. Check the address, and that Tailscale is on for this device.")
        case .notOnTailnet:
            String(localized: "Tailscale is off on this device. Turn it on, then try again.")
        case .unreachable:
            String(localized: "The computer didn’t answer. Make sure it’s awake and connected to Tailscale.")
        case .hostServiceNotRunning:
            String(localized: "The computer is reachable, but the Purrdr host service isn’t running. Start it on the computer, then try again.")
        case .connectionLost:
            String(localized: "The connection dropped. Try again.")
        case .unexpectedResponse:
            String(localized: "The host service sent a response Purrdr doesn’t understand. Update Purrdr and the host service.")
        case .paneChanged:
            String(localized: "This chat changed on the computer, so nothing was sent.")
        case .queueFull:
            String(localized: "The Send When Done queue is full (20 messages). Wait for some to send or delete one.")
        case .queueItemUnknown:
            String(localized: "That message already left the queue. Refreshing the list.")
        }
    }

    private static func commonMessage(for error: any Error) -> String {
        switch error {
        case SSHConnectionError.hostKeyChanged:
            String(localized: "This computer looks different from before. If you didn’t reinstall or reset it, stop and check it in Computers.")
        case SSHConnectionError.hostKeyUnverified:
            String(localized: "This computer hasn’t been confirmed yet. Test the connection in Computers.")
        case SSHConnectionError.hostNotFound:
            String(localized: "Couldn’t find this computer. Check the address, and that Tailscale is on for this device.")
        case SSHConnectionError.timedOut:
            String(localized: "The computer didn’t answer in time. Make sure it’s awake and Tailscale is on for both devices.")
        case SSHConnectionError.unreachable:
            String(localized: "Couldn’t reach this computer. Make sure Tailscale is on for both devices.")
        case SSHConnectionError.tailscaleCheckCancelled:
            String(localized: "Tailscale sign-in was canceled. Try again when you’re ready to sign in.")
        case SSHConnectionError.tailscaleCheckTimedOut:
            String(localized: "The Tailscale sign-in wasn’t finished in time. Try again.")
        case SSHConnectionError.connectionLost, SSHConnectionError.channelRejected:
            String(localized: "The connection dropped. Try again.")
        case HostProbeError.herdrNotInstalled:
            String(localized: "herdr isn’t installed on this computer, or it isn’t at the saved location.")
        case HostProbeError.notHerdr:
            String(localized: "The herdr path runs a different program. Check the herdr path.")
        case HostProbeError.serverNotRunning:
            String(localized: "herdr isn’t running on this computer. Open herdr there, then test again.")
        case HostProbeError.unsupportedOperatingSystem:
            String(localized: "Purrdr supports macOS, Linux, and Windows computers.")
        case WindowsCommandError.unsupported:
            String(localized: "This isn’t available on Windows computers yet.")
        case WindowsCommandError.commandTooLong:
            String(localized: "This request is too long for a Windows computer.")
        case HostProbeError.herdr(let message):
            message
        case HostProbeError.updateFailed(let message):
            String(localized: "Couldn’t update herdr. \(message)")
        default:
            String(localized: "Couldn’t reach this computer. Try again.")
        }
    }
}

/// Windows 主機還沒有 PowerShell 版本的功能(主題、用量等以 `localizedDescription` 顯示錯誤的地方)。
extension WindowsCommandError: LocalizedError {
    public var errorDescription: String? { HostErrorText.message(for: self) }
}
