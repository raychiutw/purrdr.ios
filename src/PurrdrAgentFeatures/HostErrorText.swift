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
                String(localized: "This host doesn’t accept password sign-in over SSH. Use a key instead, or turn on PasswordAuthentication in the host’s sshd settings.")
            default:
                String(localized: "This host doesn’t accept key sign-in over SSH. Check PubkeyAuthentication in the host’s sshd settings.")
            }
        case SSHConnectionError.connectionRefused:
            connection == .openSSH
                ? String(localized: "The host refused the connection. Check that Remote Login (SSH) is on and the port is right.")
                : String(localized: "The host refused the connection. Check that Tailscale SSH is on and the port is right.")
        case HostCredentialError.missingSecret:
            String(localized: "This host’s password or key isn’t on this device. Edit the host and enter it again.")
        case DeviceKeyError.secureEnclaveUnavailable:
            String(localized: "This device can’t create a key in the Secure Enclave. Import a key or use a password.")
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
            String(localized: "RSA keys aren’t supported. Use this device’s key, or an ed25519 or ECDSA key.")
        case .unsupportedKeyType(let type):
            String(localized: "\(type) keys aren’t supported. Use this device’s key, or an ed25519 or ECDSA key.")
        case .unsupportedFormat:
            String(localized: "This isn’t an OpenSSH private key. Paste the whole file, starting with “-----BEGIN OPENSSH PRIVATE KEY-----”. To convert an older key, run ssh-keygen -p -f on it.")
        case .publicKeyInsteadOfPrivate:
            String(localized: "This is a public key. Paste the private key file instead (the one without .pub).")
        case .passphraseProtected:
            // 只用系統加密，不解 passphrase(見 SSHKeyImportError.passphraseProtected)。
            String(localized: "Keys protected by a passphrase aren’t supported. On your computer, remove the passphrase with ssh-keygen -p -N \"\" -f <key file>, then paste the key again.")
        case .malformed:
            String(localized: "This key is incomplete or damaged. Paste the whole file again.")
        }
    }

    private static func authenticationFailed(
        connection: HostConfiguration.ConnectionMethod?, authentication: HostConfiguration.OpenSSHAuthentication?
    ) -> String {
        switch (connection, authentication) {
        case (.tailscaleSSH?, _):
            String(localized: "Tailscale SSH didn’t let this user log in. Check the user name and your tailnet’s SSH rules.")
        case (.openSSH?, .password?):
            String(localized: "The host didn’t accept this user name and password.")
        case (.openSSH?, .deviceKey?):
            String(localized: "The host didn’t accept this device’s key. Add the public key to ~/.ssh/authorized_keys on the host, and check the user name.")
        case (.openSSH?, _):
            String(localized: "The host didn’t accept this key. Check that its public key is in ~/.ssh/authorized_keys on the host, and check the user name.")
        case (nil, _), (.https?, _):
            String(localized: "The host didn’t let this user sign in. Edit the host to check the user name and how Purrdr signs in.")
        }
    }

    /// HTTPS 連線方式(主機服務)的說明。權杖失效時引導重新配對。
    package static func hostServiceMessage(_ error: HostServiceError) -> String {
        String(localized: "The connection dropped. Try again.")
    }

    private static func commonMessage(for error: any Error) -> String {
        switch error {
        case SSHConnectionError.hostKeyChanged:
            String(localized: "This host identifies itself with a different key. If you didn’t reinstall or reset it, stop and check it in Hosts.")
        case SSHConnectionError.hostKeyUnverified:
            String(localized: "This host’s key hasn’t been confirmed yet. Test the connection in Hosts.")
        case SSHConnectionError.hostNotFound:
            String(localized: "Couldn’t find this host name. Check the address and that this device is on your tailnet.")
        case SSHConnectionError.timedOut:
            String(localized: "The host didn’t answer in time. Make sure it’s awake and both devices are on your tailnet.")
        case SSHConnectionError.unreachable:
            String(localized: "Couldn’t reach this host. Make sure both devices are on your tailnet.")
        case SSHConnectionError.tailscaleCheckCancelled:
            String(localized: "Tailscale sign-in was canceled. Try again when you’re ready to sign in.")
        case SSHConnectionError.tailscaleCheckTimedOut:
            String(localized: "The Tailscale sign-in wasn’t finished in time. Try again.")
        case SSHConnectionError.connectionLost, SSHConnectionError.channelRejected:
            String(localized: "The connection dropped. Try again.")
        case HostProbeError.herdrNotInstalled:
            String(localized: "herdr isn’t installed on this host, or it isn’t at the herdr path.")
        case HostProbeError.notHerdr:
            String(localized: "The herdr path runs a different program. Check the herdr path.")
        case HostProbeError.serverNotRunning:
            String(localized: "herdr isn’t running in this session on the host. Start herdr on the host, then test again.")
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
