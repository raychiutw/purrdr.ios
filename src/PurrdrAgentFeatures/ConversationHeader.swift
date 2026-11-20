import Foundation
import PurrdrCore

/// 對話標題列(#270,原型 purrdr-screens 定案版):標題是 workspace 名稱，下一行是狀態(字與點)與主機名。
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

    public init(title: String, status: Status, segments: [String]) {
        self.title = title
        self.status = status
        self.segments = segments
    }

    /// 畫面寬度不夠時依序嘗試的文字：最長的在前，每次從後面整段拿掉，最後只剩狀態。
    public var displayVariants: [String] {
        (0...segments.count).reversed().map { count in
            ([status.title] + segments.prefix(count)).joined(separator: " · ")
        }
    }

    /// 完整內容(VoiceOver):workspace、狀態、主機。
    public var accessibilityText: String {
        ([title] + [lineAccessibilityText]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// 標題下一行(狀態、主機)的 VoiceOver 文字;標題是另一個元素，不重複念。
    public var lineAccessibilityText: String {
        ([status.title] + segments).joined(separator: ", ")
    }

    package init(agent: Agent?, title: String, status: AgentStatus?, isOffline: Bool, hostName: String?) {
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
        case .offline: String(localized: "Offline")
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
