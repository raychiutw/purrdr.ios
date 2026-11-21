import Foundation
import PurrdrCore

/// 離開期間摘要(#308;spec #298 故事 22):離開超過 15 分鐘再回到聊天時，離開期間開頭的一條分隔線
/// 「你離開期間 · N 輪 · 工作 M 分鐘」，可收合那段。
///
/// 主機服務沒有活動摘要訊息(協定裡找不到)，所以由 app 依對話紀錄項目的時間與離開時間自己算。
/// 一「輪」是從一則使用者訊息(或離開後第一個項目)到下一則使用者訊息之前、Agent 至少回過一次文字的一段;
/// 工作時間是每一輪第一個到最後一個有時間的項目之間的差，相加後四捨五入成分鐘。
package struct AwaySummary: Equatable, Sendable {
    /// 分隔線擺在這個項目之前(離開後的第一個項目)。
    package var anchorID: String
    package var turns: Int
    package var workMinutes: Int
    /// 離開期間 Agent 的最後一句;收合時它留在畫面上。
    package var lastReplyID: String

    package init(anchorID: String, turns: Int, workMinutes: Int, lastReplyID: String) {
        self.anchorID = anchorID
        self.turns = turns
        self.workMinutes = workMinutes
        self.lastReplyID = lastReplyID
    }

    /// 離開多久才算「離開」。
    package static let threshold: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - awayFrom: 上次離開這個聊天的時間(`ChatPreferences.opened`)。
    ///   - cutoff: 這次進來的時間;之後的項目是在聊天開著時發生的，不算離開期間。
    package static func make(items: [ConversationItem], awayFrom: Date, cutoff: Date) -> AwaySummary? {
        guard cutoff.timeIntervalSince(awayFrom) >= threshold else { return nil }
        var anchorID: String?
        var lastReplyID: String?
        var turns = 0
        var seconds: TimeInterval = 0
        var dates: [Date] = []
        var hasReply = false

        func closeTurn() {
            if hasReply, let first = dates.min(), let last = dates.max() {
                turns += 1
                seconds += last.timeIntervalSince(first)
            } else if hasReply {
                turns += 1
            }
            dates = []
            hasReply = false
        }

        for item in items {
            if let date = item.date {
                if date <= awayFrom && anchorID == nil { continue }
                if date > cutoff { break }
            } else if anchorID == nil {
                continue
            }
            anchorID = anchorID ?? item.id
            if case .user = item { closeTurn() }
            if let date = item.date { dates.append(date) }
            if case .agentText = item {
                hasReply = true
                lastReplyID = item.id
            }
        }
        closeTurn()
        guard let anchorID, let lastReplyID, turns > 0 else { return nil }
        return AwaySummary(anchorID: anchorID, turns: turns, workMinutes: Int((seconds / 60).rounded()), lastReplyID: lastReplyID)
    }

    /// 收合時要藏起來的列：分隔線之後到最後一句之前。
    package func hiddenIDs(in ids: [String]) -> Set<String> {
        guard let start = ids.firstIndex(of: anchorID), let end = ids.firstIndex(of: lastReplyID), start < end else { return [] }
        return Set(ids[start..<end])
    }

    /// 列表列的徽章:有還沒讀的回覆，而且上次開啟已經是 15 分鐘以前。
    package static func rowIsAway(isUnread: Bool, openedAt: Date?, now: Date) -> Bool {
        guard isUnread, let openedAt else { return false }
        return now.timeIntervalSince(openedAt) >= threshold
    }
}
