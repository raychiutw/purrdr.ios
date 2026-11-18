import PurrdrCore

extension HostConfiguration {
    /// 改 SSH 主機的連線欄位，連線方式與登入方式不變;HTTPS 主機原樣傳回。
    public func editingSSH(_ change: (inout SSHSettings) -> Void) -> HostConfiguration {
        var host = self
        switch connection {
        case .tailscaleSSH(var settings):
            change(&settings)
            host.connection = .tailscaleSSH(settings)
        case .openSSH(var settings, let authentication):
            change(&settings)
            host.connection = .openSSH(settings, authentication: authentication)
        case .https:
            break
        }
        return host
    }
}
