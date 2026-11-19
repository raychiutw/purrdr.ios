import Foundation

/// 跟隨尾端時捲到哪裡(#191、#210)。
public enum ConversationFollowTarget: Equatable, Sendable {
    /// 捲到這一列的底部。
    case row(String)
    /// 捲到內容底部。
    case bottomEdge

    public static let workingRowID = "working"
    public static let panelRowID = "panel"
    public static let promptRowID = "prompt"

    /// 列表最底下那一列：工作中指示、面板、問題卡片、最後一列對話依序優先。
    public static func target(showsWorkingRow: Bool, showsPanel: Bool, showsPromptCard: Bool, lastEntryID: String?) -> Self {
        .bottomEdge
    }
}
