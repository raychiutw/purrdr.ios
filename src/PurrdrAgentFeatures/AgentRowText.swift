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
        parts.append(AgentKind.displayName(agent.kind) ?? String(localized: "Terminal"))
        if let folder, !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    /// 人取的 workspace 名稱：不等於(不分大小寫)任何 pane 資料夾最後一段的名稱(依主機的路徑語法，#26)。
    package static func humanLabel(_ label: String?, siblings: [Agent]) -> String? {
        guard let label else { return nil }
        let folders = siblings.compactMap { $0.cwd.flatMap(HostPathSyntax.lastComponent)?.lowercased() }
        return folders.contains(label.lowercased()) ? nil : label
    }

    /// Session 標題：哪個欄位才是標題依 agent 種類而定;預設終端機標題、resume 指令、像 session id 的字串都不算。
    package static func sessionTitle(of agent: Agent) -> String? {
        let candidate: String? = switch agent.kind {
        // Codex 的 `title` 是被截斷的第一個 prompt;真正的名稱是終端機標題去掉結尾「 | 資料夾」。
        case "codex": agent.terminalTitle.flatMap { title in
            title.range(of: " | ", options: .backwards).map { String(title[..<$0.lowerBound]) }
        }
        case "grok": agent.terminalTitle.flatMap(grokTitle)
        default: agent.sessionTitle ?? agent.terminalTitle
        }
        guard let title = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !isDefaultTerminalTitle(title) else { return nil }
        return title
    }

    /// Grok:取「 - grok」前一段，去掉前導 spinner 與「Action Required」。
    private static func grokTitle(_ terminalTitle: String) -> String? {
        var title = terminalTitle
        if let suffix = title.range(of: " - grok", options: [.backwards, .caseInsensitive]) {
            title = String(title[..<suffix.lowerBound])
        }
        title = title.replacingOccurrences(of: "Action Required", with: "")
        title = String(title.drop { !$0.isLetter && !$0.isNumber })
        return title
    }

    private static let defaultTitles: Set<String> = ["claude code", "claude", "codex", "grok", "omp", "agy"]

    private static func isDefaultTerminalTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if defaultTitles.contains(lowered) { return true }
        if lowered.contains("--resume") || lowered.contains("--continue") || lowered.hasPrefix("codex resume") { return true }
        // 含 UUID 片段(8-4 位十六進位)的多半是 session id。
        return lowered.contains(/[0-9a-f]{8}-[0-9a-f]{4}/)
    }

    /// 依主機的路徑語法(#26:Windows 是 `C:\…`)。
    private static func lastTwoSegments(_ path: String) -> String {
        HostPathSyntax.trailingComponents(path, count: 2)
    }
}

/// agent 種類。由 herdr 的種類字串解析;沒有專屬樣式的種類保留原文。
package enum AgentKind: Equatable {
    case claudeCode
    case codex
    case gemini
    case openCode
    case copilot
    case unknown(String)

    package init(rawKind: String) {
        self = switch rawKind {
        case "claude": .claudeCode
        case "codex": .codex
        case "gemini": .gemini
        case "open_code": .openCode
        case "github_copilot": .copilot
        default: .unknown(rawKind)
        }
    }

    /// 顯示名稱。不認得的種類照 herdr 原文;沒有種類時 `nil`。
    package var displayName: String? {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .openCode: "opencode"
        case .copilot: "GitHub Copilot"
        case .unknown(let rawKind): Self.otherDisplayName(rawKind)
        }
    }

    /// herdr 種類字串的顯示名稱。
    package static func displayName(_ kind: String) -> String? {
        AgentKind(rawKind: kind).displayName
    }

    /// 沒有專屬樣式的種類。
    private static func otherDisplayName(_ kind: String) -> String? {
        switch kind {
        case "": nil
        case "grok": "Grok"
        case "agy", "antigravity": "Antigravity"
        case "pi": "Pi"
        case "omp": "OMP"
        case "cline": "Cline"
        case "amp": "Amp"
        case "droid": "Droid"
        default: kind
        }
    }
}
