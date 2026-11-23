import PurrdrCore

/// 偵測主機上裝了哪些 Agent(#477):唯讀,看家目錄裡各 Agent 的設定資料夾(`HostAgentSettings.configurationFolder`)在不在。
/// 不跑 Agent 本身、不寫主機。連不上主機時丟出錯誤(不當作一個都沒裝),呼叫端下次再偵測。
public struct HostAgentDetector: Sendable {
    let files: HostFiles

    public init(files: HostFiles) {
        self.files = files
    }

    public func installedAgents(among candidates: [AgentID] = HostAgentSettings.configurable) async throws -> Set<AgentID> {
        let folders = candidates.compactMap { agent in
            HostAgentSettings.configurationFolder(for: agent).map { (agent: agent, path: HostPath($0)) }
        }
        let read = try await files.read(folders.map(\.path))
        return Set(
            folders.compactMap { folder in
                switch read.files[folder.path] ?? .missing {
                case .missing, .missingDirectory: nil
                case .file, .notRegularFile, .unreadable, .tooLarge: folder.agent
                }
            })
    }
}
