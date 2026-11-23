import Foundation
@testable import PurrdrCore
import Testing

/// 主機的 Agent 設定規則(#477):初始化、啟用過濾與設定值的存讀。
@Suite("主機的 Agent 設定")
struct HostAgentSettingsTests {
    @Test("新增主機:偵測到的才預先打開,設定頁沒有的種類不收")
    func initialFromDetection() {
        #expect(HostAgentSettings.initial(detected: [.claude, .agy, .gemini]) == [.claude, .agy])
        #expect(HostAgentSettings.initial(detected: []).isEmpty)
    }

    @Test("既有主機升級:目前顯示用量的 Claude Code 與 Codex 加上偵測結果")
    func migratedKeepsShownUsage() {
        #expect(HostAgentSettings.migrated(detected: []) == [.claude, .codex])
        #expect(HostAgentSettings.migrated(detected: [.agy]) == [.claude, .codex, .agy])
    }

    @Test("還沒設定過(nil)的主機沿用升級前的行為;設定過就以設定為準,可以全關")
    func effectiveValue() {
        #expect(HostAgentSettings.effective(nil) == [.claude, .codex])
        #expect(HostAgentSettings.effective([.agy]) == [.agy])
        #expect(HostAgentSettings.effective([]).isEmpty)
    }

    @Test("新增聊天只列啟用的 Agent,順序固定")
    func newChatAgentsOnlyEnabled() {
        #expect(HostAgentSettings.newChatAgents(enabled: [.codex, .agy]) == [.codex, .agy])
        #expect(HostAgentSettings.newChatAgents(enabled: [.claude, .codex]) == [.claude, .codex])
        #expect(HostAgentSettings.newChatAgents(enabled: []).isEmpty)
    }

    @Test("用量:設定頁有開關的種類看開關,沒有開關的種類不受影響")
    func usageFilter() {
        #expect(HostAgentSettings.showsUsage(of: .codex, enabled: [.claude]) == false)
        #expect(HostAgentSettings.showsUsage(of: .claude, enabled: [.claude]))
        #expect(HostAgentSettings.showsUsage(of: .gemini, enabled: []))
    }

    @Test("每個可設定的 Agent 都有偵測用的設定資料夾")
    func everyConfigurableAgentHasFolder() {
        for agent in HostAgentSettings.configurable {
            #expect(HostAgentSettings.configurationFolder(for: agent) != nil, "\(agent.canonicalName)")
        }
    }

    static let legacyJSON = #"{"id":"6F1C2A4E-3B7D-4C8E-9A10-2B3C4D5E6F70","name":"A","connection":{"method":"tailscaleSSH","endpoint":{"host":"a","port":22,"username":"u"},"herdr":{"path":"herdr"}}}"#

    @Test("主機設定存讀:有設定的存成種類名稱;沒設定的沒有這個欄位,讀回 nil")
    func codingRoundTrip() throws {
        var host = HostConfiguration(name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"))
        host.enabledAgents = [.claude, .agy]
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(HostConfiguration.self, from: data).enabledAgents == [.claude, .agy])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["enabledAgents"] as? [String])?.sorted() == ["agy", "claude"])

        host.enabledAgents = []
        #expect(try JSONDecoder().decode(HostConfiguration.self, from: JSONEncoder().encode(host)).enabledAgents == [])

        host.enabledAgents = nil
        let plain = try JSONEncoder().encode(host)
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(plainObject["enabledAgents"] == nil)
        #expect(try JSONDecoder().decode(HostConfiguration.self, from: plain).enabledAgents == nil)
    }

    @Test("舊資料(沒有欄位)讀得懂,不認得的種類名稱以其他種類保留")
    func legacyItemAndUnknownNames() throws {
        #expect(try JSONDecoder().decode(HostConfiguration.self, from: Data(Self.legacyJSON.utf8)).enabledAgents == nil)
        let future = Self.legacyJSON.replacingOccurrences(of: #""name":"A","#, with: #""name":"A","enabledAgents":["claude","mystery"],"#)
        #expect(try JSONDecoder().decode(HostConfiguration.self, from: Data(future.utf8)).enabledAgents == [.claude, .other("mystery")])
    }

    @Test("主機同步套用結果不洗掉這支裝置的 Agent 設定(不同步)")
    func syncKeepsLocalAgentSettings() {
        var existing = HostConfiguration(name: "Studio", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"))
        existing.enabledAgents = [.agy]
        let synced = SyncedHost(
            id: existing.id, name: "Studio renamed", endpoint: SSHEndpoint(host: "studio-mac", username: "demo"),
            connectionMethod: .tailscaleSSH, hostKeyPin: nil, modifiedAt: Date())
        #expect(synced.applied(to: existing)?.enabledAgents == [.agy])
        #expect(synced.applied(to: existing)?.name == "Studio renamed")
        #expect(synced.applied(to: nil)?.enabledAgents == nil)
    }
}
