import Foundation
import PurrdrCore

/// 未讀、釘選與需處理數量的規則(#41;行為規格 F2.2、F2.5、F2.6、F2.8)。
///
/// 未讀是推導值，不存旗標：本機只存每個 session 最後開啟的時間(`ChatPreferences.opened`,依主機分開)。
/// 聊天以「主機 + session」識別，所以 herdr 回收 pane 給新 session 時，新 session 沒有開啟紀錄、重新算未讀。
package enum ChatUnread {
    /// 一列在本機的聊天狀態。
    package struct State {
        package var isUnread = false
        package var pinnedAt: Date?
        package var isMuted = false

        package init() {}

        package init(agent: Agent, source: AgentListProjection.Source, visible: Set<ChatRoute>) {
            let isVisible = visible.contains(ChatRoute(host: source.host, paneID: agent.paneID))
            isUnread = ChatUnread.isUnread(
                session: agent.sessionID, preview: source.previews[agent.paneID], opened: source.preferences.opened, isVisible: isVisible)
            if let session = agent.sessionID {
                pinnedAt = source.preferences.pinned[session]
                isMuted = source.preferences.muted.contains(session)
            }
        }

        /// 右欄的狀態記號：未讀的回覆是 `done`(實心圓)、已讀是 `idle`(空心圓),不論 herdr 最後回報 done 或 idle。
        /// 需要你、工作中照 herdr;`unknown` 已讀時維持灰色。
        package func displayStatus(_ status: AgentStatus) -> AgentStatus {
            switch status {
            case .blocked, .working: status
            case .done, .idle, .unknown: isUnread ? .done : (status == .unknown ? .unknown : .idle)
            }
        }
    }

    /// - 不算未讀：目前開著的聊天;沒有 session(開啟紀錄無處可記，點永遠清不掉);沒有預覽;預覽是自己送出的;預覽沒有時間。
    /// - 算未讀：這個 session 從未開啟過，或預覽時間晚於最後開啟時間。
    package static func isUnread(session: String?, preview: MessagePreview?, opened: [String: Date], isVisible: Bool) -> Bool {
        guard !isVisible, let session, let preview, !preview.isFromUser, let date = preview.date else { return false }
        guard let openedAt = opened[session] else { return true }
        return date > openedAt
    }

    /// 需要處理的 workspace 數：有 blocked 或未讀 Agent 的 workspace 各算一次。
    /// 目前開著的聊天不算：開著的 Agent 所在的 workspace 只算兄弟的 blocked(行為規格 F2.8)。
    package static func attentionCount(sources: [AgentListProjection.Source], visible: Set<ChatRoute>) -> Int {
        sources.reduce(0) { count, source in
            guard let snapshot = source.snapshot else { return count }
            let byWorkspace = Dictionary(grouping: snapshot.agents, by: \.workspaceID)
            return count + byWorkspace.values.filter { agents in
                let visibleHere = agents.contains { visible.contains(ChatRoute(host: source.host, paneID: $0.paneID)) }
                return agents.contains { agent in
                    if visible.contains(ChatRoute(host: source.host, paneID: agent.paneID)) { return false }
                    if agent.effectiveStatus == .blocked { return true }
                    return !visibleHere && State(agent: agent, source: source, visible: visible).isUnread
                }
            }.count
        }
    }
}

// MARK: - 滑動提示

/// 「使用者已經用過滑動面板的動作」的本機紀錄(滑動提示只到第一次為止，行為規格 F2.7)。
@MainActor
public protocol SwipeHintStore: AnyObject {
    var isDismissed: Bool { get }
    func dismiss()
}

/// 只在記憶體：測試與 UI 測試用(每次啟動都顯示提示)。
@MainActor
public final class InMemorySwipeHintStore: SwipeHintStore {
    public private(set) var isDismissed: Bool

    public init(isDismissed: Bool = false) { self.isDismissed = isDismissed }

    public func dismiss() { isDismissed = true }
}

/// 存在 `UserDefaults`(只在這支裝置)。
@MainActor
public final class UserDefaultsSwipeHintStore: SwipeHintStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "swipeHintDismissed") {
        self.defaults = defaults
        self.key = key
    }

    public var isDismissed: Bool { defaults.bool(forKey: key) }

    public func dismiss() { defaults.set(true, forKey: key) }
}
