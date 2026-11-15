import Foundation

/// Tailscale SSH check mode(重新驗證)。
///
/// 依 Tailscale 文件與原始碼(見 `docs/research/tailscale-ssh-check-mode.md`):ACL 規則的 action 是 `check` 時，
/// tailscaled 在 SSH 認證階段送一則**認證橫幅**(SSH_MSG_USERAUTH_BANNER)帶驗證網址，接著**不回覆認證結果**,
/// 等使用者在瀏覽器登入(最多約 30 分鐘);登入完成才回認證成功，連線照常繼續。
public enum TailscaleCheck {
    /// 從 SSH 認證橫幅取出驗證網址;不是 check mode 的橫幅回 `nil`。
    ///
    /// 橫幅內容由 Tailscale 控制端決定、沒有固定格式，所以只認「提到 authenticate 且帶 https 網址」的橫幅，
    /// 一般的登入橫幅(即使帶網址)不算。只接受 https,不開其他 scheme。
    public static func authenticationURL(inBanner banner: String) -> URL? {
        guard banner.range(of: "authenticate", options: .caseInsensitive) != nil else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'"))
        for token in banner.components(separatedBy: separators) where token.lowercased().hasPrefix("https://") {
            if let url = URL(string: token), url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
                return url
            }
        }
        return nil
    }
}

/// 等待中的 Tailscale SSH check mode:畫面顯示驗證網址，可一鍵開啟，也可取消等待。
public struct TailscaleCheckPrompt: Sendable {
    /// 在瀏覽器開啟完成驗證的網址。
    public let url: URL
    private let cancelAction: @Sendable () async -> Void

    public init(url: URL, cancel: @escaping @Sendable () async -> Void) {
        self.url = url
        cancelAction = cancel
    }

    /// 不等了:關掉這次連線，等待中的指令以 `SSHConnectionError.tailscaleCheckCancelled` 結束。
    public func cancel() async {
        await cancelAction()
    }
}

/// 主機通道回報 check mode 狀態：開始等待時給提示，結束(完成、失敗或取消)時給 `nil`。
public typealias TailscaleCheckObserver = @Sendable (TailscaleCheckPrompt?) -> Void
