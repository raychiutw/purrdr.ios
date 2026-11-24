import Foundation
import PurrdrCore

/// 聊天列表最上面的「需要你」段落(#531、spec #528):需要你的聊天各一列(新變成需要你的在前),最新轉變的那一列標「剛剛」。
/// 這些列同時留在原本「主機 · Workspace」段落;所有主機都算(不受目前主機篩選),搜尋照常套用,沒有時整段不顯示(`nil`)。
public struct NeedsYouSection: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public var tab: SpacesTab
        /// 最新「轉變」成需要你的那一列(`NeedsYouNotifications.latest`)。
        public var isJustNow: Bool
        public var id: String { tab.id }
    }

    public var rows: [Row]

    /// 段落標題:「N 個聊天需要你」。
    public static func title(count: Int) -> String {
        count == 1 ? String(localized: "1 chat needs you") : String(localized: "\(count) chats need you")
    }

    /// 最新轉變那一列尾端的標記(畫面與 VoiceOver 共用)。
    public static var justNowText: String { String(localized: "Just now") }
}

extension AgentListProjection {
    /// - Parameter order: `NeedsYouNotifications.others`(依「變成需要你的時間」新的在前,已排除靜音與目前開著的聊天);
    ///   段落只列有 pane 在裡面的 Tab。
    /// - Parameter justNow: 最新轉變成需要你的聊天(`NeedsYouNotifications.latest`);沒有時 `nil`。
    package static func needsYouSection(
        sources: [Source], visible: Set<ChatRoute> = [], query: String = "", order: [ChatRoute] = [], justNow: ChatRoute? = nil
    ) -> NeedsYouSection? {
        func rank(_ tab: SpacesTab) -> Int {
            order.firstIndex { $0.host == tab.host && tab.blockedPaneIDs.contains($0.paneID) } ?? Int.max
        }
        func isListed(_ tab: SpacesTab) -> Bool { rank(tab) != Int.max }
        let tabs = spacesSections(sources: sources, visible: visible, query: query)
            .flatMap(\.tabs)
            .filter(isListed)
        guard !tabs.isEmpty else { return nil }
        let rows = tabs.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { _, tab in
                NeedsYouSection.Row(
                    tab: tab, isJustNow: justNow.map { $0.host == tab.host && tab.blockedPaneIDs.contains($0.paneID) } ?? false)
            }
        return NeedsYouSection(rows: rows)
    }
}
