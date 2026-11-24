import Foundation
import PurrdrCore

/// 對話標題列(#270、#514):兩行——第一行 Tab 名稱，第二行主機名稱、狀態與(非一般的)權限模式。
/// 只依輸入推導，不記任何狀態。
///
/// 畫面寬度不夠時從後面整段拿掉，不截斷;VoiceOver 念 `accessibilityText`(workspace、狀態、主機)。
public struct ConversationHeader: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case offline
        case working
        case needsYou
        case done
        /// 連得上、agent 閒置或狀態不明。
        case online
    }

    /// Workspace 名稱;還沒讀到 Agent 時是聊天標題。
    public var title: String
    public var status: Status
    /// 狀態之後的段落：主機名(有的話)。
    public var segments: [String]
    /// context 百分比與待辦進度(#307);空的時候不顯示。
    public var progress: AgentProgress
    /// 從畫面讀到的權限模式(Claude);還沒讀到或不是 Claude 是 `nil`。
    public var permissionMode: AgentPermissionMode?
    /// Tab 名稱(#476,snapshot 的 Tab label;預設數字名稱是「Tab N」);還沒讀到 snapshot 是空字串。
    public var tabName: String

    public init(
        title: String, status: Status, segments: [String], progress: AgentProgress = AgentProgress(),
        permissionMode: AgentPermissionMode? = nil, tabName: String = ""
    ) {
        self.tabName = tabName
        self.title = title
        self.status = status
        self.segments = segments
        self.progress = progress
        self.permissionMode = permissionMode
    }

    /// 膠囊第二行的權限模式標示(#380):一般模式與讀不到時不顯示;略過權限是警示(面板外也看得到)。
    public struct PermissionBadge: Equatable, Sendable {
        public var mode: AgentPermissionMode
        public var isWarning: Bool
        public init(mode: AgentPermissionMode, isWarning: Bool) {
            self.mode = mode
            self.isWarning = isWarning
        }
    }

    public var permissionBadge: PermissionBadge? {
        guard let permissionMode, permissionMode != .normal else { return nil }
        return PermissionBadge(mode: permissionMode, isWarning: permissionMode == .bypassPermissions)
    }

    /// 對應列表那組 Agent 狀態符號;離線不是 Agent 狀態(畫 `wifi.slash`),所以是 `nil`。
    public var agentStatus: AgentStatus? {
        switch status {
        case .offline: nil
        case .working: .working
        case .needsYou: .blocked
        case .done: .done
        case .online: .idle
        }
    }

    /// 頂列一行尾端的 context 百分比(「62%」);沒有時為 `nil`。待辦只在狀態 sheet(#349,同一資訊只出現一處)。
    public var progressText: String? {
        progress.contextPercent.map { "\($0)%" }
    }

    /// 畫面寬度不夠時依序嘗試的文字：最長的在前，每次從後面整段拿掉，最後只剩狀態。
    public var displayVariants: [String] {
        let plain = (0...segments.count).reversed().map { count in
            ([status.title] + segments.prefix(count)).joined(separator: " · ")
        }
        // 有進度時先試帶進度的(「Working · studio · 62%」),放不下再整段拿掉主機名，最後才拿掉進度(#307)。
        guard let progressText else { return plain }
        return plain.map { "\($0) · \(progressText)" } + plain
    }

    /// 單行標題膠囊的名稱(#476):Tab 名稱;還沒讀到 snapshot 時退回 Workspace 名稱。
    public var capsuleName: String { tabName.isEmpty ? title : tabName }

    /// 兩行標題的第二行(#514):電腦圖示＋主機名稱 · 狀態,權限模式不是一般時尾端加符號與短名。
    /// 標題不可點;這裡只描述內容,圖示與狀態點由畫面畫。
    public struct SecondLine: Equatable, Sendable {
        /// 每台主機各一個名稱;沒有主機名稱時為空(不畫電腦圖示)。
        public var hostNames: [String]
        public var statusTitle: String
        public var badge: PermissionBadge?

        /// 純文字(測試與除錯):「Studio Mac · Working · Plan」。
        public var text: String {
            var parts: [String] = []
            if !hostNames.isEmpty { parts.append(hostNames.joined(separator: ", ")) }
            parts.append(statusTitle)
            if let badge { parts.append(badge.mode.displayName) }
            return parts.joined(separator: " · ")
        }
    }

    public var secondLine: SecondLine {
        SecondLine(hostNames: segments.filter { !$0.isEmpty }, statusTitle: status.title, badge: permissionBadge)
    }

    /// 完整內容(VoiceOver):Tab 名稱、主機、狀態、權限模式。
    public var accessibilityText: String {
        ([capsuleName] + [lineAccessibilityText]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// 標題第二行(主機、狀態、權限模式)的 VoiceOver 文字;第一行是另一個元素，不重複念。
    public var lineAccessibilityText: String {
        (segments + [status.title] + (permissionBadge.map { [$0.mode.displayName] } ?? [])).joined(separator: ", ")
    }

    package init(agent: Agent?, title: String, status: AgentStatus?, isOffline: Bool, hostName: String?, progress: AgentProgress = AgentProgress(), permissionMode: AgentPermissionMode? = nil, tabName: String = "") {
        self.tabName = tabName
        self.progress = progress
        self.permissionMode = permissionMode
        self.title = agent.map(AgentRowText.workspaceName) ?? title
        self.status = if isOffline {
            .offline
        } else {
            switch status {
            case .working: .working
            case .blocked: .needsYou
            case .done: .done
            case .idle, .unknown, nil: .online
            }
        }
        segments = hostName.flatMap { $0.isEmpty ? nil : [$0] } ?? []
    }
}

extension ConversationHeader.Status {
    public var title: String {
        switch self {
        case .offline: String(localized: "Reconnecting…")
        // 與列表共用 Agent 狀態的狀態字。
        case .working: String(localized: AgentStatus.working.title)
        case .needsYou: String(localized: AgentStatus.blocked.title)
        case .done: String(localized: AgentStatus.done.title)
        case .online: String(localized: "Online")
        }
    }
}

/// 工作中指示的經過時間：「12s」「11m 43s」「1h 5m」(行為規格 F5.11)。
public enum WorkingElapsed {
    public static func text(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

extension AgentPermissionMode {
    /// 權限模式的顯示名(膠囊第二行、面板選項、VoiceOver 共用)。
    public var displayName: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .acceptEdits: String(localized: "Accept Edits")
        case .plan: String(localized: "Plan")
        case .bypassPermissions: String(localized: "Bypass Permissions")
        case .auto: String(localized: "Auto")
        case .dontAsk: String(localized: "Don’t Ask")
        }
    }
}
