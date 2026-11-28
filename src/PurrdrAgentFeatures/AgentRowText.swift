import Foundation
import PurrdrCore

/// 列的標題與副標(行為規格 F2.4)。只依 snapshot 的內容推導，不記任何狀態。
package enum AgentRowText {
    /// 標題取第一個非空者：
    /// - 單一 agent 的 workspace:herdr agent 名稱 > 人取的 workspace 名稱 > session 標題 > workspace 名稱 > workspace id。
    /// - 多 agent 的 workspace:herdr agent 名稱 > session 標題 > workspace 名稱 > workspace id。
    ///   人取的名稱是整個 workspace 共用的，拿來當每個 agent 的標題會讓兄弟列全部同名;
    ///   沒有自己標題的 agent 改在副標附序號(行為規格 F2.1)。
    package static func title(for agent: Agent, siblings: [Agent]) -> String {
        if let name = agent.name { return name }
        if siblings.count <= 1, let label = humanLabel(agent.workspaceLabel, siblings: siblings) { return label }
        return sessionTitle(of: agent) ?? agent.workspaceLabel ?? agent.workspaceID
    }

    /// 副標以「 · 」連接：workspace 名稱(標題不是它、也不是已顯示的資料夾段時)、序號、agent 顯示名、資料夾最後兩段。
    package static func subtitle(for agent: Agent, title: String, siblings: [Agent]) -> String {
        let folder = agent.cwd.map(lastTwoSegments)
        let folderSegments = Set(HostPathSyntax.components(folder ?? "").map { $0.lowercased() })
        var parts: [String] = []
        if let label = agent.workspaceLabel, label != title, !folderSegments.contains(label.lowercased()) {
            parts.append(label)
        }
        if siblings.count > 1, agent.name == nil, sessionTitle(of: agent) == nil,
           let index = siblings.firstIndex(where: { $0.paneID == agent.paneID }) {
            parts.append(String(localized: "\(index + 1) of \(siblings.count)"))
        }
        parts.append(AgentID.displayName(forHerdrName: agent.kind) ?? String(localized: "Terminal"))
        if let folder, !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    /// Agents 列第一行與聊天標題的 workspace 名稱(#269、#270,原型 B):herdr 的 workspace 名稱(人取的或資料夾名);
    /// 沒有時退回資料夾最後一段，再沒有是 workspace id。
    package static func workspaceName(for agent: Agent) -> String {
        if let label = agent.workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        if let folder = agent.cwd.flatMap(HostPathSyntax.lastComponent).map(String.init), !folder.isEmpty { return folder }
        return agent.workspaceID
    }

    /// 人取的 workspace 名稱：不等於(不分大小寫)任何 pane 資料夾最後一段的名稱(依主機的路徑語法，#26)。
    package static func humanLabel(_ label: String?, siblings: [Agent]) -> String? {
        guard let label else { return nil }
        let folders = siblings.compactMap { $0.cwd.flatMap(HostPathSyntax.lastComponent)?.lowercased() }
        return folders.contains(label.lowercased()) ? nil : label
    }

    /// Session 標題:哪個欄位才是標題依 Agent 設定檔的 session 組而定。
    package static func sessionTitle(of agent: Agent) -> String? {
        AgentCatalog.profile(forHerdrName: agent.kind).session.title(sessionTitle: agent.sessionTitle, terminalTitle: agent.terminalTitle)
    }

    /// 依主機的路徑語法(#26:Windows 是 `C:\…`)。
    private static func lastTwoSegments(_ path: String) -> String {
        HostPathSyntax.trailingComponents(path, count: 2)
    }
}

extension AgentID {
    /// 顯示名稱(取自 Agent 設定檔)。不認得的種類照 herdr 原文;沒有種類時 `nil`。
    package var displayName: String? {
        AgentCatalog.profile(for: self).presentation.displayName
    }

    /// herdr 種類字串的顯示名稱。
    package static func displayName(forHerdrName kind: String) -> String? {
        AgentID(herdrName: kind).displayName
    }
}
