/// 聊天列表「⋯」選單的項目(#241)。會員與 Purrdr Plus 不在選單裡，從帳號入口進入。
enum MoreMenuItem: String, CaseIterable, Sendable {
    case newChat, hosts, planUsage, loginShell, files, settings

    /// UI 測試找選單項目用。
    var accessibilityIdentifier: String { "menu.\(rawValue)" }

    /// 以分隔線分成三組：新增聊天／主機工具／設定。HTTPS 主機沒有登入 Shell 與檔案(ADR-0010)。
    static func groups(supportsShell: Bool) -> [[MoreMenuItem]] {
        let hostTools: [MoreMenuItem] = supportsShell ? [.hosts, .planUsage, .loginShell, .files] : [.hosts, .planUsage]
        return [[.newChat], hostTools, [.settings]]
    }
}
