import Foundation
import PurrdrAgentFeatures
import PurrdrFeatures
import Testing

/// 方案用量畫面上次選的主機與 Agent 存在 UserDefaults,重開 app 後還原(#177)。
@MainActor
@Suite("方案用量的上次選擇")
struct PlanUsageSelectionStoreTests {
    static let mac = HostSelection.host(UUID(uuidString: "6F1C2A4E-0B7D-4C1E-9A55-0D2C8E1F3A10")!)
    static let linux = HostSelection.host(UUID(uuidString: "1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D")!)
    static let hosts = [PlanUsageHostOption(id: mac, name: "Mac"), PlanUsageHostOption(id: linux, name: "Linux")]

    let suite = "purrdr.tests.planUsageSelection.\(UUID().uuidString)"

    func reopen() -> PlanUsageModel {
        let store = UserDefaultsPlanUsageSelectionStore(defaults: UserDefaults(suiteName: suite)!)
        return PlanUsageModel(hosts: Self.hosts, fallback: Self.mac, store: store) { _, _ in nil }
    }

    @Test("重開 app 後還原上次選的主機與 Agent")
    func restoresAfterRelaunch() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = reopen()
        model.select(host: Self.linux)
        model.select(agent: .codex)

        let relaunched = reopen()

        #expect(relaunched.host == Self.linux)
        #expect(relaunched.agent == .codex)
    }

    @Test("沒存過或存的值讀不懂：退回選取中主機與 Claude Code")
    func unreadableFallsBack() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        #expect(reopen().host == Self.mac)

        defaults.set(["host": "not-a-host", "agent": "codex"], forKey: UserDefaultsPlanUsageSelectionStore.defaultKey)

        #expect(reopen().host == Self.mac)
        #expect(reopen().agent == .claudeCode)
    }
}
