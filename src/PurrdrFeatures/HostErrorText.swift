import PurrdrCore

/// 連線與 herdr 錯誤的白話說明。函式庫的錯誤字串不給使用者看(行為規格 §7.6)。
enum HostErrorText {
    static func message(for error: any Error) -> String {
        switch error {
        case SSHConnectionError.hostKeyChanged:
            String(localized: "This host identifies itself with a different key. If you didn’t reinstall or reset it, stop and check it in Hosts.")
        case SSHConnectionError.hostKeyUnverified:
            String(localized: "This host’s key hasn’t been confirmed yet. Test the connection in Hosts.")
        case SSHConnectionError.connectionRefused:
            String(localized: "The host refused the connection. Check that Tailscale SSH is on and the port is right.")
        case SSHConnectionError.hostNotFound:
            String(localized: "Couldn’t find this host name. Check the address and that this device is on your tailnet.")
        case SSHConnectionError.timedOut:
            String(localized: "The host didn’t answer in time. Make sure it’s awake and both devices are on your tailnet.")
        case SSHConnectionError.unreachable:
            String(localized: "Couldn’t reach this host. Make sure both devices are on your tailnet.")
        case SSHConnectionError.authenticationFailed:
            String(localized: "Tailscale SSH didn’t let this user log in. Check the user name and your tailnet’s SSH rules.")
        case SSHConnectionError.connectionLost, SSHConnectionError.channelRejected:
            String(localized: "The connection dropped. Try again.")
        case HostProbeError.herdrNotInstalled:
            String(localized: "herdr isn’t installed on this host, or it isn’t at the herdr path.")
        case HostProbeError.notHerdr:
            String(localized: "The herdr path runs a different program. Check the herdr path.")
        case HostProbeError.serverNotRunning:
            String(localized: "herdr isn’t running in this session on the host. Start herdr on the host, then test again.")
        case HostProbeError.unsupportedOperatingSystem:
            String(localized: "Purrdr supports macOS and Linux hosts for now.")
        case HostProbeError.herdr(let message):
            message
        case HostProbeError.updateFailed(let message):
            String(localized: "Couldn’t update herdr. \(message)")
        default:
            String(localized: "Couldn’t reach this host. Try again.")
        }
    }
}
