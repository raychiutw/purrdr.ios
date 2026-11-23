/// 一台主機上「裝了哪些 Agent」的設定規則(#477、ADR-0013):只有啟用的 Agent 才查用量、才出現在這台主機的新增聊天。
/// Agent 列表不受影響:herdr 回報的 Agent 照常顯示與開啟。
///
/// 設定存在主機設定(`HostConfiguration.enabledAgents`);`nil` 是「還沒設定過」(舊版 app 存的主機),
/// 初始化前沿用升級前的行為,第一次連得上時以偵測結果補齊。
public enum HostAgentSettings {
    /// 設定頁列出、可以開關的 Agent(app 能開新聊天的種類,順序同新增聊天)。
    public static let configurable: [AgentID] = AgentCatalog.startableAgents

    /// 升級前就會顯示用量的 Agent:Claude Code 與 Codex 一律列在用量區(Antigravity 要偵測到才列,所以靠偵測結果)。
    public static let previouslyShownUsage: Set<AgentID> = Set(configurable.filter { AgentCatalog.profile(for: $0).footprint.showedUsageBeforeSettings })

    /// 實際生效的集合:還沒設定過的主機沿用升級前的行為。
    public static func effective(_ stored: Set<AgentID>?) -> Set<AgentID> {
        stored ?? previouslyShownUsage
    }

    /// 新增主機:偵測到的才預先打開。
    public static func initial(detected: Set<AgentID>) -> Set<AgentID> {
        detected.intersection(configurable)
    }

    /// 既有主機升級後第一次初始化:目前顯示用量的 Agent 加上偵測結果,行為不突然改變。
    public static func migrated(detected: Set<AgentID>) -> Set<AgentID> {
        previouslyShownUsage.union(detected.intersection(configurable))
    }

    /// 新增聊天選單要列的 Agent(只列啟用的,順序同 `configurable`)。
    public static func newChatAgents(enabled: Set<AgentID>) -> [AgentID] {
        configurable.filter(enabled.contains)
    }

    /// 這個 Agent 的用量要不要查與顯示。設定頁列不出來的種類(沒有開關)不受這個設定影響,一律 `true`。
    public static func showsUsage(of agent: AgentID, enabled: Set<AgentID>) -> Bool {
        !configurable.contains(agent) || enabled.contains(agent)
    }

    /// 主機上放這個 Agent 設定的資料夾(相對於家目錄),偵測用:資料夾在就當作裝了。資料在 Agent 設定檔的 `footprint`。
    public static func configurationFolder(for agent: AgentID) -> String? {
        AgentCatalog.profile(for: agent).footprint.configurationFolder
    }
}
