import Foundation
import PurrdrCore

/// 把 snapshot 投影成列表的 section(行為規格 F2.2–F2.4)。純函式：同樣的輸入永遠得到同樣的列表。
///
/// 之後的擴充點：多主機(#39)把多台的 snapshot 合併後再投影;Spaces 檢視(#40)是另一種投影;
/// 已釘選群組(#41)在 `AgentGroup` 最前面加一組。
enum AgentListProjection {
    static func sections(snapshot: HostSnapshot?, query: String, previews: [String: MessagePreview]) -> [AgentSection] {
        guard let snapshot else { return [] }
        let order = Dictionary(snapshot.workspaces.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        let byWorkspace = Dictionary(grouping: snapshot.agents, by: \.workspaceID)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let entries = snapshot.agents.enumerated().compactMap { position, agent -> Entry? in
            let siblings = byWorkspace[agent.workspaceID] ?? [agent]
            let row = AgentRow(agent: agent, siblings: siblings, preview: previews[agent.paneID])
            guard needle.isEmpty || matches(needle, agent: agent, row: row) else { return nil }
            return Entry(row: row, workspaceOrder: order[agent.workspaceID] ?? .max, position: position, lastMessage: previews[agent.paneID]?.date)
        }
        let groups = Dictionary(grouping: entries) { $0.row.status.group }
        return AgentGroup.allCases.compactMap { group in
            guard let entries = groups[group], !entries.isEmpty else { return nil }
            return AgentSection(group: group, rows: entries.sorted(by: group.areInIncreasingOrder).map(\.row))
        }
    }

    struct Entry {
        var row: AgentRow
        var workspaceOrder: Int
        var position: Int
        var lastMessage: Date?

        var hostOrder: (Int, Int) { (workspaceOrder, position) }
    }

    /// 不分大小寫的子字串比對：標題、herdr 名稱、session 與終端機標題、agent 種類與顯示名、資料夾、workspace 名稱與 id。
    /// 種類與顯示名都比對，搜「Antigravity」要找得到 herdr 叫 `agy` 的(行為規格 F2.3)。
    private static func matches(_ needle: String, agent: Agent, row: AgentRow) -> Bool {
        let fields: [String?] = [
            row.title, agent.name, agent.sessionTitle, agent.terminalTitle, agent.kind, AgentKind.displayName(agent.kind),
            agent.cwd, agent.workspaceLabel, agent.workspaceID,
        ]
        return fields.contains { $0?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

extension AgentGroup {
    /// 「需要你」與「工作中」依主機順序(workspace `number`);閒置依最後訊息時間新→舊，無時間者最後。
    func areInIncreasingOrder(_ lhs: AgentListProjection.Entry, _ rhs: AgentListProjection.Entry) -> Bool {
        if self == .idle, lhs.lastMessage != rhs.lastMessage {
            guard let left = lhs.lastMessage else { return false }
            guard let right = rhs.lastMessage else { return true }
            return left > right
        }
        return lhs.hostOrder < rhs.hostOrder
    }
}

extension Agent {
    /// 列表上的狀態：非 working 但 herdr 看到選單在等按鍵(`input_pending`)→ 當成 `blocked`(行為規格 F2.2)。
    var effectiveStatus: AgentStatus {
        status != .working && inputPending ? .blocked : status
    }
}

extension AgentStatus {
    /// 「需要你」只有 `blocked`;`done`、`idle`、`unknown` 都算閒置。
    var group: AgentGroup {
        switch self {
        case .blocked: .needsYou
        case .working: .working
        case .done, .idle, .unknown: .idle
        }
    }
}

extension AgentRow {
    init(agent: Agent, siblings: [Agent], preview: MessagePreview?) {
        let status = agent.effectiveStatus
        let title = AgentRowText.title(for: agent, siblings: siblings)
        let rowPreview: Preview = if status == .blocked {
            .needsInput
        } else if let preview {
            .message(preview.text, fromYou: preview.isFromUser)
        } else {
            .status(status)
        }
        let time: Time? = status == .working ? .now : preview?.date.map(Time.date)
        self.init(
            id: agent.paneID, title: title, subtitle: AgentRowText.subtitle(for: agent, title: title, siblings: siblings),
            preview: rowPreview, time: time, status: status
        )
    }
}
