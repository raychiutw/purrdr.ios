import Observation
import PurrdrCore

/// Agent 列表畫面的 model。
@MainActor
@Observable
public final class AgentListModel {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var sections: [AgentSection] = []

    private let client: HerdrClient

    public init(client: HerdrClient) {
        self.client = client
    }

    /// 讀主機的 snapshot,依 Agent 狀態分組。
    public func load() async {
        do {
            let snapshot = try await client.snapshot()
            sections = Self.sections(for: snapshot.agents)
            phase = .loaded
        } catch let HerdrError.herdr(_, message) {
            // 未知碼保留 herdr 原文(行為規格 §3.8)。
            phase = .failed(message)
        } catch {
            phase = .failed("Couldn’t read this host’s herdr status.")
        }
    }

    private static func sections(for agents: [Agent]) -> [AgentSection] {
        let rows = Dictionary(grouping: agents, by: \.status.group)
        return AgentGroup.allCases.compactMap { group in
            guard let agents = rows[group], !agents.isEmpty else { return nil }
            return AgentSection(group: group, rows: agents.map(AgentRow.init(agent:)))
        }
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
    /// 標題：agent 名稱 > session 標題 > workspace 名稱;副標：agent 種類 · 資料夾。
    init(agent: Agent) {
        let title = agent.name ?? agent.terminalTitle ?? agent.workspaceLabel ?? agent.paneID
        let folder = agent.cwd.flatMap { $0.split(separator: "/").last.map(String.init) }
        let subtitle = [AgentKind.displayName(agent.kind), folder].compactMap { $0 }.joined(separator: " · ")
        self.init(id: agent.paneID, title: title, subtitle: subtitle, status: agent.status)
    }
}

/// agent 種類的顯示名稱。不認得的種類照 herdr 原文。
enum AgentKind {
    static func displayName(_ kind: String) -> String? {
        switch kind {
        case "": nil
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "grok": "Grok"
        case "antigravity": "Antigravity"
        case "pi": "Pi"
        case "omp": "OMP"
        default: kind
        }
    }
}

/// 列表的分組：依「需要你／工作中／閒置」排列，最需要使用者處理的在最上面。
public enum AgentGroup: CaseIterable, Sendable {
    case needsYou
    case working
    case idle
}

public struct AgentSection: Identifiable, Equatable, Sendable {
    public var group: AgentGroup
    public var rows: [AgentRow]
    public var id: AgentGroup { group }

    public init(group: AgentGroup, rows: [AgentRow]) {
        self.group = group
        self.rows = rows
    }
}

/// 列表的一列。
public struct AgentRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var status: AgentStatus

    public init(id: String, title: String, subtitle: String, status: AgentStatus) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }
}
