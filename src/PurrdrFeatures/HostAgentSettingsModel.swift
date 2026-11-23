import Foundation
import Observation
import PurrdrCore

/// 主機頁「Agent」子頁的 model(#477):逐一開關這台主機裝了哪些 Agent、標示偵測結果。
/// 只有啟用的 Agent 才查用量、才出現在這台主機的新增聊天;Agent 列表不受影響。
@MainActor
@Observable
public final class HostAgentSettingsModel {
    public enum Detection: Equatable, Sendable {
        /// 還在偵測。
        case checking
        case detected
        case notDetected
        /// 偵測失敗(主機離線):不標示,不影響開關。
        case unknown
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var agent: AgentID
        public var name: String
        public var isEnabled: Bool
        public var detection: Detection
        public var id: AgentID { agent }
    }

    public private(set) var enabled: Set<AgentID>
    private var detection: [AgentID: Detection] = [:]

    private let detect: @MainActor () async throws -> Set<AgentID>
    private let save: @MainActor (Set<AgentID>) -> Void

    public init(
        enabled: Set<AgentID>, detect: @escaping @MainActor () async throws -> Set<AgentID>, save: @escaping @MainActor (Set<AgentID>) -> Void
    ) {
        self.enabled = enabled
        self.detect = detect
        self.save = save
    }

    public var rows: [Row] {
        HostAgentSettings.configurable.map { agent in
            Row(
                agent: agent, name: Self.name(of: agent), isEnabled: enabled.contains(agent), detection: detection[agent] ?? .checking)
        }
    }

    public func row(for agent: AgentID) -> Row? {
        rows.first { $0.agent == agent }
    }

    /// 啟用中的 Agent 名稱(主機頁列的副標);全關是空陣列。
    public var enabledNames: [String] { Self.enabledNames(of: enabled) }

    /// 啟用中的 Agent 名稱(順序同新增聊天);主機頁的列不開子頁 model 時也用這個。
    public static func enabledNames(of enabled: Set<AgentID>) -> [String] {
        HostAgentSettings.configurable.filter(enabled.contains).map(name(of:))
    }

    public func setEnabled(_ agent: AgentID, _ isEnabled: Bool) {
        guard HostAgentSettings.configurable.contains(agent), enabled.contains(agent) != isEnabled else { return }
        if isEnabled { enabled.insert(agent) } else { enabled.remove(agent) }
        save(enabled)
    }

    /// 畫面出現:偵測一次,逐列標示。
    public func load() async {
        let found = try? await detect()
        for agent in HostAgentSettings.configurable {
            guard let found else {
                detection[agent] = .unknown
                continue
            }
            detection[agent] = found.contains(agent) ? .detected : .notDetected
        }
    }

    static func name(of agent: AgentID) -> String {
        AgentCatalog.profile(for: agent).presentation.displayName ?? agent.canonicalName
    }
}
