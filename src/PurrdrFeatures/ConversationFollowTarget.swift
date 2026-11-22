import Foundation

/// 跟隨尾端時捲到哪裡(#191、#210):有列就捲到最底下那一列;捲到內容底部會多捲一個底部 inset,停在內容外。
public enum ConversationFollowTarget: Equatable, Sendable {
    /// 捲到這一列的底部。
    case row(String)
    /// 捲到內容底部。
    case bottomEdge

    public static let workingRowID = "working"
    public static let promptRowID = "prompt"
    /// 撤回倒數中的訊息(#300)。
    public static let pendingSendRowID = "pendingSend"

    /// 列表最底下那一列：工作中指示、問題卡片、最後一列對話依序優先。
    public static func target(showsWorkingRow: Bool, showsPromptCard: Bool, lastEntryID: String?) -> Self {
        if showsWorkingRow { return .row(workingRowID) }
        if showsPromptCard { return .row(promptRowID) }
        return lastEntryID.map(Self.row) ?? .bottomEdge
    }
}
