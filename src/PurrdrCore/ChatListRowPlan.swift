import Foundation

/// 聊天列表的列組成(ADR-0014):對話列之外的固定列與順序，以及 snapshot 之間哪些列要重畫。純邏輯。
public enum ChatListRowPlan {
    public static let olderID = "older"
    public static let awayID = "away"
    public static let noticeID = "sendWhenDoneNotice"
    public static let promptID = "prompt"
    public static let workingID = "working"

    /// 列表由上而下的列 id:頂端固定一列、對話列(離開期間分隔線在錨點列前面)、待送項目、提示、已回答的問題、工作中指示。
    /// 重複的 id 只留第一個(diffable 不允許重複)。
    public static func ids(
        includesOlder: Bool = true, rowIDs: [String], awayAnchorID: String?, pendingIDs: [String], noticeID: String?,
        showsPrompt: Bool, showsWorking: Bool
    ) -> [String] {
        var ids: [String] = []
        if includesOlder { ids.append(olderID) }
        for rowID in rowIDs {
            if rowID == awayAnchorID { ids.append(awayID) }
            ids.append(rowID)
        }
        ids += pendingIDs
        if let noticeID { ids.append(noticeID) }
        if showsPrompt { ids.append(promptID) }
        if showsWorking { ids.append(workingID) }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 前後都存在、內容不同的列 id(snapshot 要重畫這些列);依 id 排序,結果穩定。
    public static func changedIDs<Content: Equatable>(previous: [String: Content], current: [String: Content]) -> [String] {
        current.compactMap { id, content in previous[id].map { $0 != content ? id : nil } ?? nil }.sorted()
    }

    /// snapshot 要重畫的列 id:環境值改變(主機主題、玻璃設定、slash 名稱寫進了列的 hosted view)時,所有前後都存在的列;
    /// 否則只有內容有變的列(`changedIDs`)。
    public static func reconfigureIDs<Content: Equatable>(
        previous: [String: Content], current: [String: Content], environmentChanged: Bool
    ) -> [String] {
        guard environmentChanged else { return changedIDs(previous: previous, current: current) }
        return current.keys.filter { previous[$0] != nil }.sorted()
    }
}
